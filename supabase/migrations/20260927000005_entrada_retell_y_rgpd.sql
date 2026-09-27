-- ═══════════════════════════════════════════════════════════════════════════
-- Verantia Voice · 005 · Entrada firmada desde Retell + RGPD
--
--  · La firma X-Retell-Signature se verifica AQUÍ, con la API key guardada cifrada
--    en Supabase Vault (nunca en n8n ni en el JSON de los flujos).
--      Alta del secreto (SQL Editor, una sola vez):
--        select vault.create_secret('<API key de Retell>', 'retell_api_key');
--  · Minimización: a la IA (Retell) solo vuelve lo que necesita para hablar;
--    los datos de contacto van aparte, solo para las notificaciones de n8n.
--  · Limitación del plazo de conservación (art. 5.1.e RGPD): llamadas, citas y
--    clientes antiguos se anonimizan o borran solos (pg_cron diario, migración 003).
--  · Derechos de acceso y portabilidad (arts. 15 y 20): fn_export_customer.
-- ═══════════════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

alter table public.tenants
  add column if not exists url_privacidad text,                                  -- 2ª capa informativa del negocio
  add column if not exists retencion_llamadas_dias int not null default 90
    check (retencion_llamadas_dias between 7 and 365),                           -- resumen y nº del llamante
  add column if not exists retencion_clientes_meses int not null default 24
    check (retencion_clientes_meses between 1 and 120);                          -- clientes sin citas recientes

-- ─── Firma de Retell ───────────────────────────────────────────────────────
-- Formato: "v=<timestamp ms>,d=<hex HMAC-SHA256(cuerpo_crudo || timestamp, api_key)>"
create or replace function public._retell_firma_valida(p_raw text, p_signature text)
returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_ts text; v_dig text; v_key text; v_calc text;
begin
  if p_raw is null or p_signature is null then return false; end if;
  v_ts  := substring(p_signature from 'v=(\d{10,16})');
  v_dig := lower(substring(p_signature from 'd=([0-9a-fA-F]{64})'));
  if v_ts is null or v_dig is null then return false; end if;
  -- Anti-replay: la firma caduca a los 5 minutos
  if abs(extract(epoch from now()) * 1000 - v_ts::numeric) > 300000 then return false; end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'retell_api_key' limit 1;
  if v_key is null then raise exception 'Falta el secreto retell_api_key en Supabase Vault'; end if;

  v_calc := encode(extensions.hmac(p_raw || v_ts, v_key, 'sha256'), 'hex');
  -- Comparación sin fuga de tiempos: se comparan los hashes, no los valores
  return extensions.digest(v_calc, 'sha256') = extensions.digest(v_dig, 'sha256');
end $$;

-- Quita de una respuesta lo que la IA no necesita (datos de contacto, ids internos)
create or replace function public._solo_para_agente(p jsonb)
returns jsonb
language sql immutable set search_path = public as $$
  select (p - array['cliente','negocio','confirmacion','tenant_id','cita_id','aviso','telefono_transferencia','error_interno'])
         || case when p ? 'anterior'
                 then jsonb_build_object('anterior', (p->'anterior') - array['cliente','negocio','confirmacion','cita_id'])
                 else '{}'::jsonb end
$$;

-- ─── Punto de entrada 1: inicio de llamada (webhook call_inbound) ──────────
create or replace function public.fn_voz_inbound(p_raw text, p_signature text)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare b jsonb; ci jsonb; r jsonb;
begin
  if not public._retell_firma_valida(p_raw, p_signature) then
    insert into public.error_log (origen, codigo) values ('fn_voz_inbound', 'FIRMA_NO_VALIDA');
    return jsonb_build_object('ok', false, 'codigo', 'FIRMA_NO_VALIDA');
  end if;

  b  := p_raw::jsonb;
  ci := b->'call_inbound';
  r  := public.fn_tenant_context(ci->>'to_number', ci->>'from_number');

  if not coalesce((r->>'ok')::boolean, false) then
    insert into public.error_log (origen, codigo, detalle)
    values ('fn_voz_inbound', r->>'codigo', jsonb_build_object('to', ci->>'to_number', 'call_id', ci->>'call_id'));
    return r || jsonb_build_object('call_id', ci->>'call_id');
  end if;

  return r || jsonb_build_object(
    'call_id', ci->>'call_id',
    'numero_negocio', public.fn_normalize_phone(ci->>'to_number'),
    'numero_llamante', coalesce(public.fn_normalize_phone(ci->>'from_number'), ''),
    'url_privacidad', (select t.url_privacidad from public.tenants t where t.id = (r#>>'{tenant,id}')::uuid),
    'telefono_transferencia', (select t.telefono_transferencia from public.tenants t where t.id = (r#>>'{tenant,id}')::uuid));
exception when others then
  insert into public.error_log (origen, codigo, detalle)
  values ('fn_voz_inbound', sqlstate, jsonb_build_object('error', left(sqlerrm, 300)));
  return jsonb_build_object('ok', false, 'codigo', 'ERROR_TECNICO');
end $$;

-- ─── Punto de entrada 2: herramientas (custom functions) ───────────────────
-- Admite los dos formatos de Retell:
--   · completo  {name, call:{...}, args:{...}}
--   · "solo argumentos" (recomendado: la transcripción no sale de Retell) → la herramienta y
--     los números llegan en cabeceras que configuramos nosotros (x-herramienta, x-numero-negocio…)
-- Devuelve { firma_valida, agente, notificacion }:
--   · agente       → lo que n8n responde a Retell (sin datos de contacto)
--   · notificacion → lo que n8n usa para WhatsApp/SMS/email (null si no hay que avisar)
create or replace function public.fn_voz_tool(
  p_raw text, p_signature text,
  p_tool text default null, p_to text default null, p_from text default null, p_call_id text default null)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  b jsonb; v_tool text; v_args jsonb; v_to text; v_from text; v_call text;
  r jsonb; v_cod text; v_notif jsonb; v_priv text;
begin
  if not public._retell_firma_valida(p_raw, p_signature) then
    insert into public.error_log (origen, codigo) values ('fn_voz_tool', 'FIRMA_NO_VALIDA');
    return jsonb_build_object('firma_valida', false);
  end if;

  b := p_raw::jsonb;
  if b ? 'args' and b ? 'call' then
    v_tool := b->>'name';
    v_args := b->'args';
    v_to   := coalesce(b#>>'{call,to_number}',   b#>>'{call,retell_llm_dynamic_variables,numero_negocio}');
    v_from := coalesce(b#>>'{call,from_number}', b#>>'{call,retell_llm_dynamic_variables,numero_llamante}');
    v_call := b#>>'{call,call_id}';
  else
    v_tool := p_tool; v_args := b; v_to := p_to; v_from := p_from; v_call := p_call_id;
  end if;

  r := public.fn_tool_dispatch(v_to, v_from, v_call, v_tool, v_args);
  v_cod := r->>'codigo';

  v_notif := case
    when v_cod = 'CONFIRMADO' and not coalesce((r->>'repetida')::boolean, false) then r || '{"tipo":"cita_confirmada"}'
    when v_cod = 'CANCELADA'             then r || '{"tipo":"cita_cancelada"}'
    when v_cod = 'REPROGRAMADA'          then r || '{"tipo":"cita_reprogramada"}'
    when v_cod = 'DERIVACION_REGISTRADA' then r || jsonb_build_object('tipo', 'derivacion',
                                                   'llamante', public.fn_normalize_phone(v_from),
                                                   'resumen', public._clean(v_args->>'resumen', 1000))
  end;

  if v_notif is not null then
    select t.url_privacidad into v_priv from public.tenants t where t.id = (r->>'tenant_id')::uuid;
    v_notif := v_notif || jsonb_build_object('call_id', v_call, 'url_privacidad', v_priv);
  end if;

  return jsonb_build_object('firma_valida', true, 'herramienta', v_tool,
                            'agente', public._solo_para_agente(r), 'notificacion', v_notif,
                            'alerta', v_cod in ('ERROR_TECNICO','HERRAMIENTA_DESCONOCIDA'),
                            'tenant_id', r->>'tenant_id', 'call_id', v_call);
exception when others then
  insert into public.error_log (origen, codigo, detalle)
  values ('fn_voz_tool', sqlstate, jsonb_build_object('tool', v_tool, 'call_id', v_call, 'error', left(sqlerrm, 300)));
  return jsonb_build_object('firma_valida', true, 'agente', public._resp('ERROR_TECNICO'), 'notificacion', null,
                            'alerta', true, 'call_id', v_call);
end $$;

-- ─── Punto de entrada 3: eventos de llamada (webhook de Retell) ────────────
-- Solo procesa call_analyzed. Guarda duración/resultado; transcripción solo si el negocio la activó.
create or replace function public.fn_voz_event(p_raw text, p_signature text)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare b jsonb; c jsonb; a jsonb; r jsonb; v_ok boolean; v_esc boolean; v_motivo text;
begin
  if not public._retell_firma_valida(p_raw, p_signature) then
    insert into public.error_log (origen, codigo) values ('fn_voz_event', 'FIRMA_NO_VALIDA');
    return jsonb_build_object('ok', false, 'codigo', 'FIRMA_NO_VALIDA');
  end if;

  b := p_raw::jsonb;
  if b->>'event' is distinct from 'call_analyzed' then
    return jsonb_build_object('ok', true, 'ignorado', true, 'evento', b->>'event');
  end if;

  c := b->'call';
  a := coalesce(c->'call_analysis', '{}'::jsonb);
  v_ok := case when a->>'call_successful' in ('true','false') then (a->>'call_successful')::boolean end;

  r := public.fn_log_call(jsonb_build_object(
    'call_id', c->>'call_id',
    'to_number', coalesce(c->>'to_number', c#>>'{retell_llm_dynamic_variables,numero_negocio}'),
    'from_number', c->>'from_number',
    'start_timestamp', c->>'start_timestamp',
    'end_timestamp', c->>'end_timestamp',
    'transcripcion', c->>'transcript',
    'resumen', a->>'call_summary',
    'resultado', case when c->>'disconnection_reason' ilike '%transfer%' then 'transferida'
                      when v_ok then 'resuelta' when v_ok = false then 'no_resuelta' else 'sin_analisis' end));

  select cl.escalada, cl.motivo_escalada into v_esc, v_motivo from public.calls cl where cl.call_id = c->>'call_id';

  return r || jsonb_build_object(
    'call_id', c->>'call_id',
    -- Aviso al negocio: solo si la llamada no se resolvió y no hubo ya una derivación (esa se avisó en el momento)
    'avisar_negocio', (v_ok = false) and not coalesce(v_esc, false) and (r->>'whatsapp_negocio') is not null,
    'llamante', public.fn_normalize_phone(c->>'from_number'),
    'resumen', public._clean(a->>'call_summary', 1000),
    'exceso_minutos', (r->>'minutos_incluidos') is not null
                      and (r->>'minutos_mes')::numeric > (r->>'minutos_incluidos')::numeric);
exception when others then
  insert into public.error_log (origen, codigo, detalle)
  values ('fn_voz_event', sqlstate, jsonb_build_object('error', left(sqlerrm, 300)));
  return jsonb_build_object('ok', false, 'codigo', 'ERROR_TECNICO');
end $$;

-- ─── Vigilancia diaria (n8n, cron) ─────────────────────────────────────────
-- Sin datos personales: solo contadores. De paso mantiene activo el proyecto del plan gratuito.
create or replace function public.fn_voz_health()
returns jsonb
language plpgsql stable set search_path = public as $$
declare v_cron boolean := false;
begin
  if to_regclass('cron.job') is not null then
    execute $q$select exists (select 1 from cron.job where jobname = 'verantia-purga-rgpd' and active)$q$ into v_cron;
  end if;
  return jsonb_build_object(
    'ok', true,
    'negocios_activos', (select count(*) from public.tenants where activo),
    'llamadas_24h', (select count(*) from public.calls where created_at > now() - interval '24 hours'),
    'derivadas_24h', (select count(*) from public.calls where escalada and created_at > now() - interval '24 hours'),
    'errores_24h', (select count(*) from public.error_log where created_at > now() - interval '24 hours'),
    'errores_por_codigo', coalesce((select jsonb_object_agg(codigo, n) from (
        select coalesce(codigo, '?') codigo, count(*) n from public.error_log
        where created_at > now() - interval '24 hours' group by 1) x), '{}'::jsonb),
    'purga_programada', v_cron);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- RGPD
-- ═══════════════════════════════════════════════════════════════════════════
-- Purga diaria ampliada: ahora también limita cuánto tiempo se guardan llamadas, citas y clientes.
create or replace function public.fn_purge_expired()
returns jsonb
language plpgsql volatile set search_path = public as $$
declare n_tr int; n_llam int; n_citas int; n_cli int; n_err int;
begin
  -- 1. Transcripciones caducadas (solo existen si el negocio las activó)
  update public.calls set transcripcion = null, transcripcion_expira_at = null
  where transcripcion_expira_at < now();
  get diagnostics n_tr = row_count;

  -- 2. Llamadas antiguas: se conserva la duración (facturación) y se borra lo personal
  update public.calls c set from_number = null, resumen = null
  from public.tenants t
  where c.tenant_id = t.id and c.created_at < now() - make_interval(days => t.retencion_llamadas_dias)
    and (c.from_number is not null or c.resumen is not null);
  get diagnostics n_llam = row_count;

  -- 3. Citas antiguas: anonimizadas (el negocio conserva estadísticas, no personas)
  update public.appointments a set nombre_cliente = '[caducado]', notas = null, customer_id = null
  from public.tenants t
  where a.tenant_id = t.id and a.fin < now() - make_interval(months => t.retencion_clientes_meses)
    and a.nombre_cliente <> '[caducado]';
  get diagnostics n_citas = row_count;

  -- 4. Clientes sin ninguna cita vigente y sin actividad en el plazo
  delete from public.customers c using public.tenants t
  where c.tenant_id = t.id and c.updated_at < now() - make_interval(months => t.retencion_clientes_meses)
    and not exists (select 1 from public.appointments a where a.customer_id = c.id);
  get diagnostics n_cli = row_count;

  -- 5. Registro técnico
  delete from public.error_log where created_at < now() - interval '90 days';
  get diagnostics n_err = row_count;

  return jsonb_build_object('transcripciones_borradas', n_tr, 'llamadas_anonimizadas', n_llam,
                            'citas_anonimizadas', n_citas, 'clientes_borrados', n_cli, 'errores_borrados', n_err);
end $$;

-- Derecho de acceso / portabilidad: todo lo que hay de un teléfono en un negocio, en JSON
create or replace function public.fn_export_customer(p_tenant uuid, p_telefono text)
returns jsonb
language plpgsql stable set search_path = public as $$
declare v_tel text := public.fn_normalize_phone(p_telefono); c public.customers;
begin
  if v_tel is null then return jsonb_build_object('ok', false, 'codigo', 'FALTA_TELEFONO'); end if;
  select * into c from public.customers where tenant_id = p_tenant and telefono = v_tel;
  return jsonb_build_object(
    'ok', true,
    'generado', now(),
    'negocio', (select jsonb_build_object('nombre', t.nombre, 'direccion', t.direccion) from public.tenants t where t.id = p_tenant),
    'cliente', case when c.id is null then null
                    else jsonb_build_object('telefono', c.telefono, 'nombre', c.nombre, 'email', c.email,
                                            'alta', c.created_at, 'ultima_actualizacion', c.updated_at) end,
    'citas', coalesce((select jsonb_agg(jsonb_build_object(
                'referencia', a.referencia, 'nombre', a.nombre_cliente, 'servicio', s.nombre,
                'inicio', a.inicio, 'fin', a.fin, 'estado', a.estado, 'canal', a.canal, 'notas', a.notas,
                'creada', a.created_at) order by a.inicio)
              from public.appointments a join public.services s on s.id = a.service_id
              where a.tenant_id = p_tenant and a.customer_id = c.id), '[]'::jsonb),
    'llamadas', coalesce((select jsonb_agg(jsonb_build_object(
                'fecha', cl.iniciada_at, 'duracion_seg', cl.duracion_seg, 'resultado', cl.resultado,
                'resumen', cl.resumen, 'transcripcion', cl.transcripcion) order by cl.iniciada_at)
              from public.calls cl
              where cl.tenant_id = p_tenant and public.fn_normalize_phone(cl.from_number) = v_tel), '[]'::jsonb));
end $$;

-- ─── Permisos: solo service_role ───────────────────────────────────────────
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname in ('_retell_firma_valida','_solo_para_agente','fn_voz_inbound','fn_voz_tool',
                               'fn_voz_event','fn_voz_health','fn_purge_expired','fn_export_customer')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
