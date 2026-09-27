-- ═══════════════════════════════════════════════════════════════════════════
-- Verantia Voice · 002 · Lógica de disponibilidad y reservas
--
-- Punto de entrada para n8n:
--   fn_tenant_context(to_number, from_number)                 → inicio de llamada
--   fn_tool_dispatch(to_number, from_number, call_id, tool, args) → herramientas
--   fn_log_call(payload)                                     → fin de llamada
--   fn_purge_expired() / fn_forget_customer(...)             → RGPD
--
-- Contrato: docs/asistente-telefonico-ia/CONTRATO_HERRAMIENTAS.md
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── Utilidades de normalización y parseo seguro ───────────────────────────
create or replace function public._norm(p text) returns text
language sql stable set search_path = public, extensions as $$
  select nullif(regexp_replace(lower(extensions.unaccent(btrim(coalesce(p, '')))), '\s+', ' ', 'g'), '')
$$;

-- Limpia texto libre: sin caracteres de control, espacios colapsados, longitud máxima.
create or replace function public._clean(p text, p_max int) returns text
language sql immutable as $$
  select nullif(left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), p_max), '')
$$;

-- Teléfono → E.164. Acepta formatos españoles habituales. null si no es válido.
create or replace function public.fn_normalize_phone(p text) returns text
language plpgsql immutable as $$
declare x text;
begin
  if p is null then return null; end if;
  x := regexp_replace(p, '[\s\.\-\(\)/]', '', 'g');
  if x ~ '^00' then x := '+' || substr(x, 3); end if;
  if x ~ '^[6789][0-9]{8}$'        then return '+34' || x; end if;
  if x ~ '^34[6789][0-9]{8}$'      then return '+' || x; end if;
  if x ~ '^\+[1-9][0-9]{7,14}$'    then return x; end if;
  return null;
end $$;

create or replace function public._parse_date(p text) returns date
language plpgsql immutable as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return p::date;
exception when others then return null;
end $$;

create or replace function public._parse_time(p text) returns time
language plpgsql immutable as $$
begin
  if p is null or p !~ '^([01]?\d|2[0-3]):[0-5]\d$' then return null; end if;
  return p::time;
end $$;

create or replace function public._parse_int(p text, p_min int, p_max int) returns int
language plpgsql immutable as $$
declare v int;
begin
  if p is null or p !~ '^\s*\d{1,4}\s*$' then return null; end if;
  v := btrim(p)::int;
  return case when v between p_min and p_max then v end;
end $$;

create or replace function public._dia_es(p date) returns text
language sql immutable as $$
  select (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[extract(isodow from p)::int]
$$;

create or replace function public._hhmm(p timestamptz, p_tz text) returns text
language sql stable as $$ select to_char(p at time zone p_tz, 'HH24:MI') $$;

-- Pista en castellano para el LLM según el código
create or replace function public._mensaje(p_codigo text) returns text
language sql immutable as $$
  select case p_codigo
    when 'DISPONIBLE'            then 'Hueco libre. Pide los datos que falten (nombre) y crea la cita.'
    when 'OCUPADO'               then 'Ese hueco está ocupado. Ofrece las alternativas indicadas; no inventes horas.'
    when 'FUERA_DE_HORARIO'      then 'Fuera del horario o el servicio no termina antes del cierre. Informa del horario y ofrece alternativas.'
    when 'DIA_CERRADO'           then 'El negocio no abre ese día. Ofrece el próximo día disponible.'
    when 'DIA_BLOQUEADO'         then 'Ese día el negocio está cerrado (festivo o cierre). No ofrezcas horas de ese día.'
    when 'FECHA_PASADA'          then 'Esa fecha u hora ya ha pasado. Pide otra.'
    when 'DEMASIADO_PRONTO'      then 'No se puede reservar con tan poca antelación. Ofrece la primera hora válida.'
    when 'DEMASIADO_LEJOS'       then 'Todavía no se admiten reservas para esa fecha. Pide una fecha más cercana.'
    when 'FALTA_SERVICIO'        then 'Pregunta qué servicio quiere.'
    when 'SERVICIO_NO_ENCONTRADO' then 'Ese servicio no está en el catálogo. Ofrece los más parecidos del catálogo.'
    when 'PROFESIONAL_NO_ENCONTRADO' then 'No hay ningún profesional con ese nombre. Ofrece reservar con cualquiera.'
    when 'PROFESIONAL_NO_REALIZA_SERVICIO' then 'Esa persona no realiza ese servicio. Ofrece otro profesional.'
    when 'CAPACIDAD_EXCEDIDA'    then 'No hay mesa para tantas personas. Ofrece pasar la consulta al equipo.'
    when 'GRUPO_GRANDE'          then 'Los grupos grandes los gestiona el equipo. Ofrece derivar.'
    when 'ERROR_DATOS'           then 'Algún dato no es válido (ver campo). Vuelve a preguntarlo.'
    when 'FALTA_TELEFONO'        then 'Necesitas un teléfono de contacto válido. Pídelo cifra a cifra.'
    when 'EMAIL_NO_VALIDO'       then 'El email no es válido. Pídelo deletreado o continúa sin email.'
    when 'NOMBRE_NO_VALIDO'      then 'Pide el nombre de la persona que vendrá.'
    when 'HUECOS_DISPONIBLES'    then 'Lee los rangos de forma natural (son horas de inicio posibles) y deja que el cliente elija; luego comprueba esa hora.'
    when 'SIN_HUECOS'            then 'No hay huecos en esas fechas. Ofrece el próximo disponible si lo hay.'
    when 'CONFIRMADO'            then 'Cita creada. Confirma día, hora, servicio y referencia (dígito a dígito).'
    when 'ERROR_OCUPADO'         then 'Alguien acaba de reservar ese hueco. Discúlpate y ofrece las alternativas.'
    when 'CITAS_ENCONTRADAS'     then 'Confirma con el cliente de qué cita se trata antes de cambiarla o anularla.'
    when 'SIN_CITAS'             then 'No hay citas a ese teléfono. Pide nombre y fecha de la cita para buscarla.'
    when 'CANCELADA'             then 'Cita anulada. Confírmalo al cliente.'
    when 'REPROGRAMADA'          then 'Cita cambiada. Confirma el nuevo día y hora.'
    when 'NO_ENCONTRADA'         then 'No existe una cita activa con esa referencia. Busca por nombre y fecha.'
    when 'NO_VERIFICADA'         then 'No se puede verificar que la cita sea suya. No des detalles; ofrece pasar con el negocio.'
    when 'FUERA_DE_PLAZO'        then 'Ya no se puede cambiar o anular por teléfono (política de cancelación). Explícalo y ofrece derivar.'
    when 'CITA_PASADA'           then 'Esa cita ya ha pasado.'
    when 'DERIVACION_REGISTRADA' then 'Si transferencia_disponible es true, transfiere la llamada; si no, di que el equipo le llamará.'
    when 'HERRAMIENTA_DESCONOCIDA' then 'Error interno. Discúlpate y ofrece tomar nota.'
    else 'Ha habido un problema técnico. Discúlpate, toma nota del motivo de la llamada y di que el equipo le llamará.'
  end
$$;

create or replace function public._resp(p_codigo text, p_extra jsonb default '{}'::jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_object('codigo', p_codigo, 'mensaje', public._mensaje(p_codigo)) || coalesce(p_extra, '{}'::jsonb)
$$;

-- ─── Resolución de servicio y profesional ──────────────────────────────────
-- Orden: código exacto → nombre exacto → sinónimo exacto → nombre que contiene / contenido.
create or replace function public._find_service(p_tenant uuid, p_texto text) returns public.services
language sql stable set search_path = public, extensions as $$
  select s.* from public.services s
  where s.tenant_id = p_tenant and s.activo and public._norm(p_texto) is not null
    and ( s.codigo = lower(btrim(p_texto))
       or public._norm(s.nombre) = public._norm(p_texto)
       or exists (select 1 from unnest(s.sinonimos) x where public._norm(x) = public._norm(p_texto))
       or public._norm(s.nombre) like '%' || public._norm(p_texto) || '%'
       or public._norm(p_texto)  like '%' || public._norm(s.nombre) || '%' )
  order by
    case when s.codigo = lower(btrim(p_texto)) then 0
         when public._norm(s.nombre) = public._norm(p_texto) then 1
         when exists (select 1 from unnest(s.sinonimos) x where public._norm(x) = public._norm(p_texto)) then 2
         else 3 end,
    s.orden, s.nombre
  limit 1
$$;

create or replace function public._find_resource(p_tenant uuid, p_texto text) returns public.resources
language sql stable set search_path = public, extensions as $$
  select r.* from public.resources r
  where r.tenant_id = p_tenant and r.activo and public._norm(p_texto) is not null
    and ( public._norm(r.nombre) = public._norm(p_texto)
       or public._norm(r.nombre) like public._norm(p_texto) || '%' )
  order by (public._norm(r.nombre) = public._norm(p_texto)) desc, r.orden
  limit 1
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- NÚCLEO: estado de un hueco concreto
-- Devuelve el código y, si está libre, el recurso asignado.
-- Se usa en la 1ª comprobación, en la 2ª (dentro de la transacción de alta) y
-- para calcular huecos. Una sola lógica → mismas respuestas en todos los sitios.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._slot_status(
  t public.tenants, s public.services, p_inicio timestamptz,
  p_comensales int default 1, p_resource uuid default null, p_excluir uuid default null,
  out codigo text, out resource_id uuid)
language plpgsql stable set search_path = public, extensions as $$
declare
  v_tz        text := t.zona_horaria;
  v_fin       timestamptz := p_inicio + make_interval(mins => s.duracion_min);
  v_bloqueo   timestamptz := v_fin + make_interval(mins => s.margen_min);
  v_l_ini     timestamp := p_inicio at time zone t.zona_horaria;
  v_l_fin     timestamp := v_fin at time zone t.zona_horaria;
  v_fecha     date := (p_inicio at time zone t.zona_horaria)::date;
  v_dow       int  := extract(isodow from (p_inicio at time zone t.zona_horaria));
  v_dia       tstzrange;
begin
  resource_id := null;

  if p_inicio < now() then codigo := 'FECHA_PASADA'; return; end if;
  if p_inicio < now() + make_interval(mins => t.antelacion_min_minutos) then codigo := 'DEMASIADO_PRONTO'; return; end if;
  if v_fecha > (now() at time zone v_tz)::date + t.reserva_max_dias then codigo := 'DEMASIADO_LEJOS'; return; end if;

  -- Festivo de la zona
  if t.zona_festivos is not null and exists (
       select 1 from public.holidays h where h.zona = t.zona_festivos and h.fecha = v_fecha) then
    codigo := 'DIA_BLOQUEADO'; return;
  end if;

  -- Día de la semana sin horario
  if not exists (select 1 from public.business_hours bh
                 where bh.tenant_id = t.id and bh.resource_id is null and bh.dia_semana = v_dow) then
    codigo := 'DIA_CERRADO'; return;
  end if;

  -- Cierre del negocio (todo el día → DIA_BLOQUEADO; parcial → OCUPADO)
  v_dia := tstzrange(v_fecha::timestamp at time zone v_tz, (v_fecha + 1)::timestamp at time zone v_tz, '[)');
  if exists (select 1 from public.closures c
             where c.tenant_id = t.id and c.resource_id is null and c.periodo @> v_dia) then
    codigo := 'DIA_BLOQUEADO'; return;
  end if;

  -- Debe caber entero en una franja del negocio (el margen de limpieza puede salirse)
  if v_l_fin::date <> v_fecha or not exists (
       select 1 from public.business_hours bh
       where bh.tenant_id = t.id and bh.resource_id is null and bh.dia_semana = v_dow
         and bh.hora_inicio <= v_l_ini::time and bh.hora_fin >= v_l_fin::time) then
    codigo := 'FUERA_DE_HORARIO'; return;
  end if;

  if exists (select 1 from public.closures c
             where c.tenant_id = t.id and c.resource_id is null
               and c.periodo && tstzrange(p_inicio, v_bloqueo, '[)')) then
    codigo := 'OCUPADO'; return;
  end if;

  -- Recurso libre que pueda hacer el servicio. Mesas: la más pequeña que sirva.
  -- Profesionales: el que menos citas tenga ese día (reparte la carga).
  select r.id into resource_id
  from public.resources r
  join public.resource_services rs on rs.resource_id = r.id and rs.service_id = s.id
  where r.tenant_id = t.id and r.activo
    and (p_resource is null or r.id = p_resource)
    and p_comensales between r.capacidad_min and r.capacidad
    and ( not exists (select 1 from public.business_hours bh where bh.resource_id = r.id)
          or exists (select 1 from public.business_hours bh
                     where bh.resource_id = r.id and bh.dia_semana = v_dow
                       and bh.hora_inicio <= v_l_ini::time and bh.hora_fin >= v_l_fin::time) )
    and not exists (select 1 from public.closures c
                    where c.resource_id = r.id and c.periodo && tstzrange(p_inicio, v_bloqueo, '[)'))
    and not exists (select 1 from public.appointments a
                    where a.resource_id = r.id and a.estado = 'confirmada'
                      and (p_excluir is null or a.id <> p_excluir)
                      and tstzrange(a.inicio, a.fin_bloqueo, '[)') && tstzrange(p_inicio, v_bloqueo, '[)'))
  order by r.capacidad,
           (select count(*) from public.appointments a2
             where a2.resource_id = r.id and a2.estado = 'confirmada'
               and a2.inicio >= lower(v_dia) and a2.inicio < upper(v_dia)),
           r.orden, r.id
  limit 1;

  if resource_id is not null then codigo := 'DISPONIBLE'; return; end if;

  -- ¿No hay mesa de ese tamaño en absoluto?
  if not exists (select 1 from public.resources r
                 join public.resource_services rs on rs.resource_id = r.id and rs.service_id = s.id
                 where r.tenant_id = t.id and r.activo and p_comensales between r.capacidad_min and r.capacidad) then
    codigo := 'CAPACIDAD_EXCEDIDA'; return;
  end if;

  codigo := 'OCUPADO';
end $$;

-- Horas de inicio libres de un día (a intervalos de paso_minutos)
create or replace function public._day_starts(
  t public.tenants, s public.services, p_fecha date,
  p_comensales int default 1, p_resource uuid default null, p_excluir uuid default null)
returns table (inicio timestamptz, resource_id uuid)
language plpgsql stable set search_path = public, extensions as $$
declare
  bh record; v_ts timestamp; st record;
  v_dur interval := make_interval(mins => s.duracion_min);
  v_paso interval := make_interval(mins => t.paso_minutos);
begin
  for bh in select b.hora_inicio, b.hora_fin from public.business_hours b
            where b.tenant_id = t.id and b.resource_id is null
              and b.dia_semana = extract(isodow from p_fecha)
            order by b.hora_inicio
  loop
    v_ts := p_fecha + bh.hora_inicio;
    while v_ts + v_dur <= p_fecha + bh.hora_fin loop
      select * into st from public._slot_status(t, s, v_ts at time zone t.zona_horaria, p_comensales, p_resource, p_excluir);
      if st.codigo = 'DISPONIBLE' then
        inicio := v_ts at time zone t.zona_horaria; resource_id := st.resource_id; return next;
      elsif st.codigo in ('DIA_BLOQUEADO','DEMASIADO_LEJOS','CAPACIDAD_EXCEDIDA') then
        return;   -- nada que hacer en este día
      end if;
      v_ts := v_ts + v_paso;
    end loop;
  end loop;
end $$;

-- Alternativas cuando la hora pedida no vale: hasta 3 horas libres ese día (las más cercanas)
-- o, si no hay, el primer hueco de los próximos 14 días.
create or replace function public._alternativas(
  t public.tenants, s public.services, p_inicio timestamptz,
  p_comensales int default 1, p_resource uuid default null, p_excluir uuid default null)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  v_fecha date := (p_inicio at time zone t.zona_horaria)::date;
  v_hoy   date := (now() at time zone t.zona_horaria)::date;
  v_alt   jsonb; d date; v_prox timestamptz;
begin
  if v_fecha >= v_hoy then
    select jsonb_agg(public._hhmm(x.inicio, t.zona_horaria) order by x.inicio) into v_alt
    from (select ds.inicio from public._day_starts(t, s, v_fecha, p_comensales, p_resource, p_excluir) ds
          order by abs(extract(epoch from ds.inicio - p_inicio)) limit 3) x;
  end if;
  if v_alt is not null then
    return jsonb_build_object('alternativas', v_alt);
  end if;

  for d in select generate_series(greatest(v_fecha + 1, v_hoy), greatest(v_fecha + 1, v_hoy) + 13, interval '1 day')::date loop
    select ds.inicio into v_prox from public._day_starts(t, s, d, p_comensales, p_resource, p_excluir) ds
    order by ds.inicio limit 1;
    if v_prox is not null then
      return jsonb_build_object('proximo_disponible', jsonb_build_object(
        'fecha', d, 'dia_semana', public._dia_es(d), 'hora', public._hhmm(v_prox, t.zona_horaria)));
    end if;
  end loop;
  return '{}'::jsonb;
end $$;

create or replace function public._servicio_json(s public.services) returns jsonb
language sql immutable as $$
  select jsonb_build_object('codigo', s.codigo, 'nombre', s.nombre, 'duracion_min', s.duracion_min,
                            'precio', s.precio, 'precio_desde', s.precio_desde)
$$;

-- Referencia de 6 dígitos única por negocio
create or replace function public._nueva_referencia(p_tenant uuid) returns text
language plpgsql volatile set search_path = public as $$
declare r text;
begin
  loop
    r := lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.appointments a where a.tenant_id = p_tenant and a.referencia = r);
  end loop;
  return r;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- HERRAMIENTAS
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── check_availability (1ª comprobación) ──────────────────────────────────
create or replace function public.fn_check_availability(
  p_tenant uuid, p_servicio text, p_fecha text, p_hora text,
  p_comensales int default 1, p_profesional text default null)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  t public.tenants; s public.services; r public.resources;
  v_fecha date := public._parse_date(p_fecha);
  v_hora  time := public._parse_time(p_hora);
  v_com   int  := coalesce(p_comensales, 1);
  v_inicio timestamptz; st record; v_out jsonb;
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;

  if public._norm(p_servicio) is null then return public._resp('FALTA_SERVICIO'); end if;
  s := public._find_service(t.id, p_servicio);
  if s.id is null then return public._resp('SERVICIO_NO_ENCONTRADO', jsonb_build_object('servicio_pedido', public._clean(p_servicio, 80))); end if;

  if v_fecha is null then return public._resp('ERROR_DATOS', '{"campo":"fecha","formato":"YYYY-MM-DD"}'); end if;
  if v_hora  is null then return public._resp('ERROR_DATOS', '{"campo":"hora","formato":"HH:MM"}'); end if;
  if v_com < 1 then return public._resp('ERROR_DATOS', '{"campo":"comensales"}'); end if;
  if v_com > t.max_comensales then return public._resp('GRUPO_GRANDE', jsonb_build_object('max_comensales', t.max_comensales)); end if;

  if public._norm(p_profesional) is not null then
    r := public._find_resource(t.id, p_profesional);
    if r.id is null then return public._resp('PROFESIONAL_NO_ENCONTRADO'); end if;
    if not exists (select 1 from public.resource_services where resource_id = r.id and service_id = s.id) then
      return public._resp('PROFESIONAL_NO_REALIZA_SERVICIO', jsonb_build_object('profesional', r.nombre));
    end if;
  end if;

  v_inicio := (v_fecha + v_hora) at time zone t.zona_horaria;
  select * into st from public._slot_status(t, s, v_inicio, v_com, r.id, null);

  v_out := jsonb_build_object(
    'fecha', v_fecha, 'dia_semana', public._dia_es(v_fecha),
    'hora_inicio', to_char(v_hora, 'HH24:MI'),
    'hora_fin', public._hhmm(v_inicio + make_interval(mins => s.duracion_min), t.zona_horaria),
    'servicio', public._servicio_json(s));

  if st.codigo = 'DISPONIBLE' then
    return public._resp('DISPONIBLE', v_out || jsonb_build_object(
      'profesional', (select nombre from public.resources where id = st.resource_id)));
  end if;

  if st.codigo in ('OCUPADO','FUERA_DE_HORARIO','DIA_CERRADO','DIA_BLOQUEADO','DEMASIADO_PRONTO','FECHA_PASADA') then
    v_out := v_out || public._alternativas(t, s, v_inicio, v_com, r.id, null);
  end if;
  return public._resp(st.codigo, v_out);
end $$;

-- ─── get_available_slots ───────────────────────────────────────────────────
create or replace function public.fn_available_slots(
  p_tenant uuid, p_servicio text, p_fecha_inicio text, p_fecha_fin text default null,
  p_comensales int default 1, p_profesional text default null, p_franja text default null)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  t public.tenants; s public.services; r public.resources;
  v_ini date := public._parse_date(p_fecha_inicio);
  v_fin date := coalesce(public._parse_date(p_fecha_fin), public._parse_date(p_fecha_inicio));
  v_com int := coalesce(p_comensales, 1);
  v_hoy date; d date; v_dias jsonb := '[]'::jsonb; v_rangos jsonb;
  v_franja text := public._norm(p_franja);
  v_prox timestamptz;
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;
  if public._norm(p_servicio) is null then return public._resp('FALTA_SERVICIO'); end if;
  s := public._find_service(t.id, p_servicio);
  if s.id is null then return public._resp('SERVICIO_NO_ENCONTRADO', jsonb_build_object('servicio_pedido', public._clean(p_servicio, 80))); end if;
  if v_ini is null then return public._resp('ERROR_DATOS', '{"campo":"fecha_inicio","formato":"YYYY-MM-DD"}'); end if;
  if v_fin < v_ini then return public._resp('ERROR_DATOS', '{"campo":"fecha_fin"}'); end if;
  if v_com > t.max_comensales then return public._resp('GRUPO_GRANDE', jsonb_build_object('max_comensales', t.max_comensales)); end if;
  if v_franja is not null and v_franja not in ('manana','tarde') then v_franja := null; end if;

  if public._norm(p_profesional) is not null then
    r := public._find_resource(t.id, p_profesional);
    if r.id is null then return public._resp('PROFESIONAL_NO_ENCONTRADO'); end if;
  end if;

  v_hoy := (now() at time zone t.zona_horaria)::date;
  v_ini := greatest(v_ini, v_hoy);
  v_fin := least(greatest(v_fin, v_ini), v_ini + 13);   -- máximo 14 días por consulta

  for d in select generate_series(v_ini, v_fin, interval '1 day')::date loop
    -- Agrupa horas de inicio consecutivas en rangos "desde–hasta"
    with starts as (
      select ds.inicio, (ds.inicio at time zone t.zona_horaria)::time as h
      from public._day_starts(t, s, d, v_com, r.id, null) ds
    ), filtrados as (
      select inicio, h from starts
      where v_franja is null or (v_franja = 'manana' and h < time '14:00') or (v_franja = 'tarde' and h >= time '14:00')
    ), grupos as (
      select inicio, inicio - (row_number() over (order by inicio)) * make_interval(mins => t.paso_minutos) as g
      from filtrados
    )
    select jsonb_agg(jsonb_build_object('desde', public._hhmm(x.desde, t.zona_horaria),
                                        'hasta', public._hhmm(x.hasta, t.zona_horaria)) order by x.desde)
      into v_rangos
    from (select min(inicio) desde, max(inicio) hasta from grupos group by g) x;

    if v_rangos is not null then
      v_dias := v_dias || jsonb_build_object('fecha', d, 'dia_semana', public._dia_es(d), 'rangos', v_rangos);
    end if;
  end loop;

  if jsonb_array_length(v_dias) > 0 then
    return public._resp('HUECOS_DISPONIBLES', jsonb_build_object('servicio', public._servicio_json(s), 'dias', v_dias));
  end if;

  -- Nada en el rango: busca el siguiente hueco en los 14 días posteriores
  for d in select generate_series(v_fin + 1, v_fin + 14, interval '1 day')::date loop
    select ds.inicio into v_prox from public._day_starts(t, s, d, v_com, r.id, null) ds order by ds.inicio limit 1;
    if v_prox is not null then
      return public._resp('SIN_HUECOS', jsonb_build_object('servicio', public._servicio_json(s),
        'proximo_disponible', jsonb_build_object('fecha', d, 'dia_semana', public._dia_es(d),
                                                 'hora', public._hhmm(v_prox, t.zona_horaria))));
    end if;
  end loop;
  return public._resp('SIN_HUECOS', jsonb_build_object('servicio', public._servicio_json(s)));
end $$;

-- ─── create_appointment (2ª comprobación, atómica) ─────────────────────────
create or replace function public.fn_create_appointment(
  p_tenant uuid, p_servicio text, p_fecha text, p_hora text,
  p_nombre text, p_telefono text, p_email text default null,
  p_comensales int default 1, p_profesional text default null, p_notas text default null,
  p_canal text default 'telefono', p_call_id text default null, p_idempotency_key text default null)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  t public.tenants; s public.services; r public.resources; a public.appointments;
  v_fecha date := public._parse_date(p_fecha);
  v_hora  time := public._parse_time(p_hora);
  v_com   int  := coalesce(p_comensales, 1);
  v_nombre text := public._clean(p_nombre, 80);
  v_tel   text := public.fn_normalize_phone(p_telefono);
  v_email text := lower(public._clean(p_email, 120));
  v_notas text := public._clean(p_notas, 500);
  v_inicio timestamptz; st record; v_cust uuid; v_canal public.canal_cita := 'telefono';
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;
  if p_canal in ('telefono','web','whatsapp','manual') then v_canal := p_canal::public.canal_cita; end if;

  -- Un alta a la vez por negocio: la 2ª comprobación y la inserción no pueden intercalarse
  -- con otra reserva del mismo negocio. (La restricción citas_sin_solape es la última red.)
  perform pg_advisory_xact_lock(hashtextextended('verantia:reserva:' || t.id::text, 0));

  -- Idempotencia: si Retell reintenta la misma petición, devolvemos la misma cita
  if p_idempotency_key is not null then
    select * into a from public.appointments where tenant_id = t.id and idempotency_key = p_idempotency_key;
    if a.id is not null then
      return public._resp('CONFIRMADO', public._cita_json(a, t) || '{"repetida": true}');
    end if;
  end if;

  -- Validación de datos
  if public._norm(p_servicio) is null then return public._resp('FALTA_SERVICIO'); end if;
  s := public._find_service(t.id, p_servicio);
  if s.id is null then return public._resp('SERVICIO_NO_ENCONTRADO', jsonb_build_object('servicio_pedido', public._clean(p_servicio, 80))); end if;
  if v_fecha is null then return public._resp('ERROR_DATOS', '{"campo":"fecha","formato":"YYYY-MM-DD"}'); end if;
  if v_hora  is null then return public._resp('ERROR_DATOS', '{"campo":"hora","formato":"HH:MM"}'); end if;
  if v_nombre is null or length(v_nombre) < 2 then return public._resp('NOMBRE_NO_VALIDO'); end if;
  if v_tel is null then return public._resp('FALTA_TELEFONO'); end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then return public._resp('EMAIL_NO_VALIDO'); end if;
  if v_com < 1 then return public._resp('ERROR_DATOS', '{"campo":"comensales"}'); end if;
  if v_com > t.max_comensales then return public._resp('GRUPO_GRANDE', jsonb_build_object('max_comensales', t.max_comensales)); end if;
  if public._norm(p_profesional) is not null then
    r := public._find_resource(t.id, p_profesional);
    if r.id is null then return public._resp('PROFESIONAL_NO_ENCONTRADO'); end if;
  end if;

  -- 2ª COMPROBACIÓN: exactamente la misma lógica que la 1ª, ahora bajo bloqueo
  v_inicio := (v_fecha + v_hora) at time zone t.zona_horaria;
  select * into st from public._slot_status(t, s, v_inicio, v_com, r.id, null);
  if st.codigo <> 'DISPONIBLE' then
    return public._resp(case when st.codigo = 'OCUPADO' then 'ERROR_OCUPADO' else st.codigo end,
                        public._alternativas(t, s, v_inicio, v_com, r.id, null));
  end if;

  -- Cliente (identificado por teléfono dentro del negocio)
  insert into public.customers (tenant_id, telefono, nombre, email)
  values (t.id, v_tel, v_nombre, v_email)
  on conflict (tenant_id, telefono) do update
    set nombre = excluded.nombre, email = coalesce(excluded.email, public.customers.email)
  returning id into v_cust;

  begin
    insert into public.appointments (tenant_id, referencia, customer_id, nombre_cliente, service_id, resource_id,
                                     inicio, fin, fin_bloqueo, comensales, canal, notas, idempotency_key, call_id)
    values (t.id, public._nueva_referencia(t.id), v_cust, v_nombre, s.id, st.resource_id,
            v_inicio, v_inicio + make_interval(mins => s.duracion_min),
            v_inicio + make_interval(mins => s.duracion_min + s.margen_min),
            v_com,
            v_canal,
            v_notas, p_idempotency_key, public._clean(p_call_id, 100))
    returning * into a;
  exception when exclusion_violation then
    return public._resp('ERROR_OCUPADO', public._alternativas(t, s, v_inicio, v_com, r.id, null));
  end;

  return public._resp('CONFIRMADO', public._cita_json(a, t));
end $$;

-- Representación de una cita para respuestas y notificaciones
create or replace function public._cita_json(a public.appointments, t public.tenants) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'cita_id', a.id, 'referencia', a.referencia,
    'fecha', (a.inicio at time zone t.zona_horaria)::date,
    'dia_semana', public._dia_es((a.inicio at time zone t.zona_horaria)::date),
    'hora_inicio', public._hhmm(a.inicio, t.zona_horaria),
    'hora_fin', public._hhmm(a.fin, t.zona_horaria),
    'comensales', a.comensales,
    'profesional', (select r.nombre from public.resources r where r.id = a.resource_id),
    'servicio', (select public._servicio_json(s) from public.services s where s.id = a.service_id),
    'cliente', (select jsonb_build_object('nombre', a.nombre_cliente, 'telefono', c.telefono, 'email', c.email)
                from public.customers c where c.id = a.customer_id),
    'confirmacion', jsonb_build_object('canal', t.canal_confirmacion, 'sms_respaldo', t.sms_respaldo),
    'negocio', jsonb_build_object('nombre', t.nombre, 'telefono', t.telefono_publico, 'direccion', t.direccion,
                                  'whatsapp_avisos', t.whatsapp_avisos, 'email_avisos', t.email_avisos))
$$;

-- ─── find_appointments ─────────────────────────────────────────────────────
create or replace function public.fn_find_appointments(
  p_tenant uuid, p_telefono_llamante text, p_telefono text default null,
  p_nombre text default null, p_fecha text default null)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  t public.tenants;
  v_tel   text := coalesce(public.fn_normalize_phone(p_telefono_llamante), public.fn_normalize_phone(p_telefono));
  v_fecha date := public._parse_date(p_fecha);
  v_citas jsonb; v_via text := 'telefono';
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;

  if v_tel is not null then
    select jsonb_agg(x.j order by x.inicio) into v_citas from (
      select a.inicio, jsonb_build_object(
        'referencia', a.referencia, 'nombre', a.nombre_cliente,
        'fecha', (a.inicio at time zone t.zona_horaria)::date,
        'dia_semana', public._dia_es((a.inicio at time zone t.zona_horaria)::date),
        'hora_inicio', public._hhmm(a.inicio, t.zona_horaria),
        'servicio', s.nombre, 'profesional', r.nombre, 'comensales', a.comensales) j
      from public.appointments a
      join public.customers c on c.id = a.customer_id
      join public.services s on s.id = a.service_id
      join public.resources r on r.id = a.resource_id
      where a.tenant_id = t.id and c.telefono = v_tel and a.estado = 'confirmada' and a.inicio > now()
      order by a.inicio limit 5) x;
  end if;

  -- Sin resultados por teléfono: solo con nombre Y fecha (evita "pescar" citas ajenas)
  if v_citas is null and public._norm(p_nombre) is not null and v_fecha is not null then
    v_via := 'nombre_fecha';
    select jsonb_agg(x.j order by x.inicio) into v_citas from (
      select a.inicio, jsonb_build_object(
        'referencia', a.referencia, 'nombre', a.nombre_cliente,
        'fecha', (a.inicio at time zone t.zona_horaria)::date,
        'dia_semana', public._dia_es((a.inicio at time zone t.zona_horaria)::date),
        'hora_inicio', public._hhmm(a.inicio, t.zona_horaria),
        'servicio', s.nombre, 'profesional', r.nombre, 'comensales', a.comensales) j
      from public.appointments a
      join public.services s on s.id = a.service_id
      join public.resources r on r.id = a.resource_id
      where a.tenant_id = t.id and a.estado = 'confirmada' and a.inicio > now()
        and (a.inicio at time zone t.zona_horaria)::date = v_fecha
        and public._norm(a.nombre_cliente) like '%' || public._norm(p_nombre) || '%'
      order by a.inicio limit 3) x;
  end if;

  if v_citas is null then return public._resp('SIN_CITAS'); end if;
  return public._resp('CITAS_ENCONTRADAS', jsonb_build_object('citas', v_citas, 'verificado_por', v_via));
end $$;

-- Verificación común para cancelar/reprogramar
create or replace function public._cita_es_del_llamante(
  a public.appointments, p_tel_llamante text, p_tel text, p_nombre text) returns boolean
language sql stable set search_path = public, extensions as $$
  select exists (select 1 from public.customers c where c.id = a.customer_id
                 and c.telefono in (public.fn_normalize_phone(p_tel_llamante), public.fn_normalize_phone(p_tel)))
      or (public._norm(p_nombre) is not null and length(public._norm(p_nombre)) >= 3
          and public._norm(a.nombre_cliente) like '%' || public._norm(p_nombre) || '%')
$$;

-- ─── cancel_appointment ────────────────────────────────────────────────────
create or replace function public.fn_cancel_appointment(
  p_tenant uuid, p_referencia text, p_telefono_llamante text,
  p_telefono text default null, p_nombre text default null)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare t public.tenants; a public.appointments; v_ref text := regexp_replace(coalesce(p_referencia, ''), '\D', '', 'g');
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;
  if v_ref !~ '^[0-9]{6}$' then return public._resp('ERROR_DATOS', '{"campo":"referencia","formato":"6 dígitos"}'); end if;

  select * into a from public.appointments
  where tenant_id = t.id and referencia = v_ref and estado = 'confirmada' for update;
  if a.id is null then return public._resp('NO_ENCONTRADA'); end if;
  if not public._cita_es_del_llamante(a, p_telefono_llamante, p_telefono, p_nombre) then
    return public._resp('NO_VERIFICADA');
  end if;
  if a.inicio <= now() then return public._resp('CITA_PASADA'); end if;
  if now() > a.inicio - make_interval(hours => t.cancelacion_min_horas) then
    return public._resp('FUERA_DE_PLAZO', jsonb_build_object('politica', t.politica_cancelacion,
                                                             'horas_minimas', t.cancelacion_min_horas));
  end if;

  update public.appointments set estado = 'cancelada', cancelada_at = now() where id = a.id returning * into a;
  return public._resp('CANCELADA', public._cita_json(a, t));
end $$;

-- ─── reschedule_appointment (atómico) ──────────────────────────────────────
create or replace function public.fn_reschedule_appointment(
  p_tenant uuid, p_referencia text, p_fecha text, p_hora text, p_telefono_llamante text,
  p_telefono text default null, p_nombre text default null,
  p_servicio text default null, p_profesional text default null)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  t public.tenants; a public.appointments; s public.services; r public.resources;
  v_ref text := regexp_replace(coalesce(p_referencia, ''), '\D', '', 'g');
  v_fecha date := public._parse_date(p_fecha);
  v_hora  time := public._parse_time(p_hora);
  v_inicio timestamptz; st record; v_antes jsonb;
begin
  select * into t from public.tenants where id = p_tenant and activo;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;
  if v_ref !~ '^[0-9]{6}$' then return public._resp('ERROR_DATOS', '{"campo":"referencia","formato":"6 dígitos"}'); end if;
  if v_fecha is null then return public._resp('ERROR_DATOS', '{"campo":"fecha","formato":"YYYY-MM-DD"}'); end if;
  if v_hora  is null then return public._resp('ERROR_DATOS', '{"campo":"hora","formato":"HH:MM"}'); end if;

  perform pg_advisory_xact_lock(hashtextextended('verantia:reserva:' || t.id::text, 0));

  select * into a from public.appointments
  where tenant_id = t.id and referencia = v_ref and estado = 'confirmada' for update;
  if a.id is null then return public._resp('NO_ENCONTRADA'); end if;
  if not public._cita_es_del_llamante(a, p_telefono_llamante, p_telefono, p_nombre) then
    return public._resp('NO_VERIFICADA');
  end if;
  if a.inicio <= now() then return public._resp('CITA_PASADA'); end if;
  if now() > a.inicio - make_interval(hours => t.cancelacion_min_horas) then
    return public._resp('FUERA_DE_PLAZO', jsonb_build_object('politica', t.politica_cancelacion,
                                                             'horas_minimas', t.cancelacion_min_horas));
  end if;

  if public._norm(p_servicio) is not null then
    s := public._find_service(t.id, p_servicio);
    if s.id is null then return public._resp('SERVICIO_NO_ENCONTRADO'); end if;
  else
    select * into s from public.services where id = a.service_id;
  end if;
  if public._norm(p_profesional) is not null then
    r := public._find_resource(t.id, p_profesional);
    if r.id is null then return public._resp('PROFESIONAL_NO_ENCONTRADO'); end if;
  end if;

  v_inicio := (v_fecha + v_hora) at time zone t.zona_horaria;
  -- Preferencia: profesional pedido → el mismo de antes → cualquiera
  select * into st from public._slot_status(t, s, v_inicio, a.comensales, coalesce(r.id, a.resource_id), a.id);
  if st.codigo = 'OCUPADO' and r.id is null then
    select * into st from public._slot_status(t, s, v_inicio, a.comensales, null, a.id);
  end if;
  if st.codigo <> 'DISPONIBLE' then
    return public._resp(st.codigo, public._alternativas(t, s, v_inicio, a.comensales, r.id, a.id));
  end if;

  v_antes := public._cita_json(a, t);
  begin
    update public.appointments
       set service_id = s.id, resource_id = st.resource_id, inicio = v_inicio,
           fin = v_inicio + make_interval(mins => s.duracion_min),
           fin_bloqueo = v_inicio + make_interval(mins => s.duracion_min + s.margen_min),
           reprogramaciones = reprogramaciones + 1
     where id = a.id returning * into a;
  exception when exclusion_violation then
    return public._resp('ERROR_OCUPADO', public._alternativas(t, s, v_inicio, a.comensales, r.id, a.id));
  end;

  return public._resp('REPROGRAMADA', public._cita_json(a, t) || jsonb_build_object('anterior', v_antes));
end $$;

-- ─── escalate_to_human ─────────────────────────────────────────────────────
create or replace function public.fn_register_escalation(
  p_tenant uuid, p_call_id text, p_from_number text, p_to_number text, p_motivo text, p_resumen text)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  t public.tenants; v_local timestamp; v_abierto boolean;
  v_motivo text := coalesce(nullif(public._norm(p_motivo), ''), 'otro');
begin
  select * into t from public.tenants where id = p_tenant;
  if t.id is null then return public._resp('ERROR_TECNICO'); end if;
  if v_motivo not in ('cliente_lo_pide','queja','fuera_de_alcance','no_entiendo','grupo_grande','otro') then
    v_motivo := 'otro';
  end if;

  if p_call_id is not null then
    insert into public.calls (call_id, tenant_id, from_number, to_number, iniciada_at, escalada, motivo_escalada, resumen)
    values (left(p_call_id, 100), t.id, p_from_number, p_to_number, now(), true, v_motivo, public._clean(p_resumen, 1000))
    on conflict (call_id) do update
      set escalada = true, motivo_escalada = excluded.motivo_escalada, resumen = excluded.resumen;
  end if;

  v_local := now() at time zone t.zona_horaria;
  v_abierto := exists (select 1 from public.business_hours bh
                       where bh.tenant_id = t.id and bh.resource_id is null
                         and bh.dia_semana = extract(isodow from v_local)
                         and v_local::time >= bh.hora_inicio and v_local::time < bh.hora_fin)
               and not exists (select 1 from public.holidays h where h.zona = t.zona_festivos and h.fecha = v_local::date)
               and not exists (select 1 from public.closures c where c.tenant_id = t.id and c.resource_id is null and c.periodo @> now());

  return public._resp('DERIVACION_REGISTRADA', jsonb_build_object(
    'transferencia_disponible', v_abierto and t.telefono_transferencia is not null,
    'telefono_transferencia', case when v_abierto then t.telefono_transferencia end,
    'motivo', v_motivo,
    'aviso', jsonb_build_object('whatsapp_negocio', t.whatsapp_avisos, 'email_negocio', t.email_avisos,
                                'negocio', t.nombre)));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PUNTOS DE ENTRADA PARA n8n
-- ═══════════════════════════════════════════════════════════════════════════

-- Único punto de entrada de las herramientas. El negocio sale del número llamado.
create or replace function public.fn_tool_dispatch(
  p_to_number text, p_from_number text, p_call_id text, p_tool text, p_args jsonb)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  v_tenant uuid;
  g jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_from text := public.fn_normalize_phone(p_from_number);   -- null si es oculto/anónimo
  v_com int;
  v_res jsonb;
begin
  select pn.tenant_id into v_tenant
  from public.phone_numbers pn join public.tenants t on t.id = pn.tenant_id
  where pn.numero = public.fn_normalize_phone(p_to_number) and pn.activo and t.activo;

  if v_tenant is null then
    insert into public.error_log (origen, codigo, detalle)
    values ('fn_tool_dispatch', 'NUMERO_NO_ASIGNADO', jsonb_build_object('to', p_to_number, 'tool', p_tool, 'call_id', p_call_id));
    return public._resp('ERROR_TECNICO');
  end if;

  v_com := coalesce(public._parse_int(g->>'comensales', 1, 999), 1);

  v_res := case p_tool
    when 'check_availability' then
      public.fn_check_availability(v_tenant, g->>'servicio', g->>'fecha', g->>'hora', v_com, g->>'profesional')
    when 'get_available_slots' then
      public.fn_available_slots(v_tenant, g->>'servicio', coalesce(g->>'fecha_inicio', g->>'fecha'), g->>'fecha_fin',
                                v_com, g->>'profesional', g->>'franja')
    when 'create_appointment' then
      public.fn_create_appointment(
        v_tenant, g->>'servicio', g->>'fecha', g->>'hora', g->>'nombre',
        coalesce(public.fn_normalize_phone(g->>'telefono'), v_from),   -- el que dicte el cliente si lo da; si no, el llamante
        g->>'email', v_com, g->>'profesional', g->>'notas', 'telefono', p_call_id,
        case when p_call_id is not null then
          md5(concat_ws('|', p_call_id, lower(g->>'servicio'), g->>'fecha', g->>'hora',
                        coalesce(public.fn_normalize_phone(g->>'telefono'), v_from))) end)
    when 'find_appointments' then
      public.fn_find_appointments(v_tenant, v_from, g->>'telefono', g->>'nombre', g->>'fecha')
    when 'cancel_appointment' then
      public.fn_cancel_appointment(v_tenant, g->>'referencia', v_from, g->>'telefono', g->>'nombre')
    when 'reschedule_appointment' then
      public.fn_reschedule_appointment(v_tenant, g->>'referencia', g->>'fecha', g->>'hora', v_from,
                                       g->>'telefono', g->>'nombre', g->>'servicio', g->>'profesional')
    when 'escalate_to_human' then
      public.fn_register_escalation(v_tenant, p_call_id, p_from_number, p_to_number, g->>'motivo', g->>'resumen')
    else public._resp('HERRAMIENTA_DESCONOCIDA')
  end;

  -- Cualquier ERROR_TECNICO se registra para que n8n avise a Verantia
  if v_res->>'codigo' in ('ERROR_TECNICO','HERRAMIENTA_DESCONOCIDA') then
    insert into public.error_log (tenant_id, origen, codigo, detalle)
    values (v_tenant, 'fn_tool_dispatch', v_res->>'codigo', jsonb_build_object('tool', p_tool, 'call_id', p_call_id));
  end if;
  return v_res || jsonb_build_object('tenant_id', v_tenant);

exception when others then
  -- Nunca un error crudo hacia la llamada. Sin datos personales en el log.
  insert into public.error_log (tenant_id, origen, codigo, detalle)
  values (v_tenant, 'fn_tool_dispatch', sqlstate, jsonb_build_object('tool', p_tool, 'call_id', p_call_id, 'error', sqlerrm));
  return public._resp('ERROR_TECNICO', jsonb_build_object('tenant_id', v_tenant, 'error_interno', true));
end $$;

-- Contexto del negocio para el inicio de la llamada (variables dinámicas del prompt)
create or replace function public.fn_tenant_context(p_to_number text, p_from_number text default null)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  t public.tenants;
  v_from text := public.fn_normalize_phone(p_from_number);
  v_hoy date; v_cliente jsonb;
begin
  select te.* into t from public.phone_numbers pn join public.tenants te on te.id = pn.tenant_id
  where pn.numero = public.fn_normalize_phone(p_to_number) and pn.activo and te.activo;
  if t.id is null then
    return jsonb_build_object('ok', false, 'codigo', 'NUMERO_NO_ASIGNADO');
  end if;
  v_hoy := (now() at time zone t.zona_horaria)::date;

  if v_from is not null then
    select jsonb_build_object('nombre', c.nombre, 'citas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'referencia', a.referencia,
               'fecha', (a.inicio at time zone t.zona_horaria)::date,
               'dia_semana', public._dia_es((a.inicio at time zone t.zona_horaria)::date),
               'hora_inicio', public._hhmm(a.inicio, t.zona_horaria),
               'servicio', s.nombre) order by a.inicio)
      from public.appointments a join public.services s on s.id = a.service_id
      where a.customer_id = c.id and a.estado = 'confirmada' and a.inicio > now()), '[]'::jsonb))
    into v_cliente
    from public.customers c where c.tenant_id = t.id and c.telefono = v_from;
  end if;

  return jsonb_build_object(
    'ok', true,
    'tenant', jsonb_build_object(
      'id', t.id, 'nombre', t.nombre, 'tipo', t.tipo, 'nombre_asistente', t.nombre_asistente, 'voz_id', t.voz_id,
      'descripcion', t.descripcion, 'direccion', t.direccion, 'telefono_publico', t.telefono_publico,
      'politica_cancelacion', t.politica_cancelacion, 'cancelacion_min_horas', t.cancelacion_min_horas,
      'antelacion_min_minutos', t.antelacion_min_minutos, 'max_comensales', t.max_comensales,
      'zona_horaria', t.zona_horaria, 'puede_transferir', t.telefono_transferencia is not null),
    'ahora_local', to_char(now() at time zone t.zona_horaria, 'YYYY-MM-DD HH24:MI'),
    'hoy', v_hoy, 'dia_semana_hoy', public._dia_es(v_hoy),
    'servicios', coalesce((select jsonb_agg(public._servicio_json(s) || jsonb_build_object(
                             'categoria', s.categoria, 'descripcion', s.descripcion,
                             'profesionales', (select jsonb_agg(r.nombre order by r.orden)
                                               from public.resource_services rs join public.resources r on r.id = rs.resource_id
                                               where rs.service_id = s.id and r.activo and r.tipo = 'profesional'))
                           order by s.orden, s.nombre)
                           from public.services s where s.tenant_id = t.id and s.activo), '[]'::jsonb),
    'horario', coalesce((select jsonb_agg(jsonb_build_object('dia', d.dia, 'dia_semana', d.nombre, 'franjas', d.franjas) order by d.dia)
                         from (select bh.dia_semana dia,
                                      (array['lunes','martes','miércoles','jueves','viernes','sábado','domingo'])[bh.dia_semana] nombre,
                                      jsonb_agg(to_char(bh.hora_inicio, 'HH24:MI') || '-' || to_char(bh.hora_fin, 'HH24:MI') order by bh.hora_inicio) franjas
                               from public.business_hours bh where bh.tenant_id = t.id and bh.resource_id is null
                               group by bh.dia_semana) d), '[]'::jsonb),
    'festivos_proximos', coalesce((select jsonb_agg(jsonb_build_object('fecha', h.fecha, 'nombre', h.nombre) order by h.fecha)
                                   from public.holidays h where h.zona = t.zona_festivos
                                     and h.fecha between v_hoy and v_hoy + 45), '[]'::jsonb),
    'cierres_proximos', coalesce((select jsonb_agg(jsonb_build_object(
                                     'desde', to_char(lower(c.periodo) at time zone t.zona_horaria, 'YYYY-MM-DD HH24:MI'),
                                     'hasta', to_char(upper(c.periodo) at time zone t.zona_horaria, 'YYYY-MM-DD HH24:MI'),
                                     'motivo', c.motivo) order by lower(c.periodo))
                                  from public.closures c where c.tenant_id = t.id and c.resource_id is null
                                    and c.periodo && tstzrange(now(), now() + interval '45 days')), '[]'::jsonb),
    'faqs', coalesce((select jsonb_agg(jsonb_build_object('pregunta', f.pregunta, 'respuesta', f.respuesta) order by f.orden)
                      from public.faqs f where f.tenant_id = t.id and f.activo), '[]'::jsonb),
    'cliente', v_cliente);
end $$;

-- Fin de llamada (webhook call_analyzed de Retell). Devuelve lo necesario para los avisos.
create or replace function public.fn_log_call(p jsonb)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  t public.tenants; v_call text := left(p->>'call_id', 100);
  v_ini timestamptz; v_fin timestamptz; v_esc boolean;
begin
  if v_call is null then return jsonb_build_object('ok', false, 'codigo', 'ERROR_DATOS'); end if;
  select te.* into t from public.phone_numbers pn join public.tenants te on te.id = pn.tenant_id
  where pn.numero = public.fn_normalize_phone(p->>'to_number');

  v_ini := case when p->>'start_timestamp' ~ '^\d{10,14}$' then to_timestamp((p->>'start_timestamp')::bigint / 1000.0) end;
  v_fin := case when p->>'end_timestamp'   ~ '^\d{10,14}$' then to_timestamp((p->>'end_timestamp')::bigint / 1000.0) end;

  insert into public.calls (call_id, tenant_id, from_number, to_number, iniciada_at, finalizada_at, duracion_seg,
                            resultado, resumen, transcripcion, transcripcion_expira_at)
  values (v_call, t.id, left(p->>'from_number', 20), left(p->>'to_number', 20), v_ini, v_fin,
          case when v_ini is not null and v_fin is not null then extract(epoch from v_fin - v_ini)::int end,
          public._clean(p->>'resultado', 40), public._clean(p->>'resumen', 1000),
          case when t.guardar_transcripcion then left(p->>'transcripcion', 50000) end,
          case when t.guardar_transcripcion then now() + make_interval(days => t.retencion_transcripcion_dias) end)
  on conflict (call_id) do update set
    tenant_id = coalesce(public.calls.tenant_id, excluded.tenant_id),
    iniciada_at = coalesce(excluded.iniciada_at, public.calls.iniciada_at),
    finalizada_at = excluded.finalizada_at, duracion_seg = excluded.duracion_seg,
    resultado = excluded.resultado,
    resumen = coalesce(public.calls.resumen, excluded.resumen),
    transcripcion = excluded.transcripcion, transcripcion_expira_at = excluded.transcripcion_expira_at
  returning escalada into v_esc;

  return jsonb_build_object('ok', true, 'tenant_id', t.id, 'negocio', t.nombre, 'escalada', v_esc,
                            'whatsapp_negocio', t.whatsapp_avisos,
                            'minutos_mes', (select round(coalesce(sum(duracion_seg), 0) / 60.0)
                                            from public.calls c where c.tenant_id = t.id
                                              and c.iniciada_at >= date_trunc('month', now())),
                            'minutos_incluidos', t.minutos_incluidos);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- RGPD
-- ═══════════════════════════════════════════════════════════════════════════
-- Ejecutar a diario (cron de n8n o pg_cron): borra transcripciones caducadas y logs viejos.
create or replace function public.fn_purge_expired()
returns jsonb
language plpgsql volatile set search_path = public as $$
declare n_tr int; n_err int;
begin
  update public.calls set transcripcion = null, transcripcion_expira_at = null
  where transcripcion_expira_at < now();
  get diagnostics n_tr = row_count;
  delete from public.error_log where created_at < now() - interval '90 days';
  get diagnostics n_err = row_count;
  return jsonb_build_object('transcripciones_borradas', n_tr, 'errores_borrados', n_err);
end $$;

-- Derecho de supresión: anonimiza al cliente y sus rastros en citas y llamadas.
-- Las citas se conservan (el negocio necesita su histórico) pero sin datos personales.
create or replace function public.fn_forget_customer(p_tenant uuid, p_telefono text)
returns jsonb
language plpgsql volatile set search_path = public as $$
declare v_tel text := public.fn_normalize_phone(p_telefono); v_cust uuid; n_citas int; n_calls int;
begin
  if v_tel is null then return jsonb_build_object('ok', false, 'codigo', 'FALTA_TELEFONO'); end if;
  select id into v_cust from public.customers where tenant_id = p_tenant and telefono = v_tel;
  update public.appointments set nombre_cliente = '[suprimido]', notas = null
  where tenant_id = p_tenant and customer_id = v_cust;
  get diagnostics n_citas = row_count;
  delete from public.customers where id = v_cust;
  update public.calls set from_number = null, transcripcion = null, resumen = null
  where tenant_id = p_tenant and public.fn_normalize_phone(from_number) = v_tel;
  get diagnostics n_calls = row_count;
  return jsonb_build_object('ok', true, 'cliente_encontrado', v_cust is not null,
                            'citas_anonimizadas', n_citas, 'llamadas_anonimizadas', n_calls);
end $$;

-- Utilidad de alta: cierre de días completos (vacaciones)
create or replace function public.fn_add_closure_days(
  p_tenant uuid, p_desde date, p_hasta date, p_motivo text default null, p_resource uuid default null)
returns uuid
language sql volatile set search_path = public as $$
  insert into public.closures (tenant_id, resource_id, periodo, motivo)
  select p_tenant, p_resource,
         tstzrange(p_desde::timestamp at time zone t.zona_horaria, (p_hasta + 1)::timestamp at time zone t.zona_horaria, '[)'),
         p_motivo
  from public.tenants t where t.id = p_tenant
  returning id
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PERMISOS: solo service_role (n8n) puede ejecutar estas funciones.
-- Postgres concede EXECUTE a PUBLIC por defecto y Supabase a anon/authenticated:
-- sin esto, cualquiera con la anon key podría llamar a fn_tool_dispatch vía API.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and (p.proname like 'fn\_%' or p.proname like '\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
