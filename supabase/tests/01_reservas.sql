-- Tests funcionales de la lógica de reservas. Se ejecutan sobre la BD con los datos demo.
-- Uso: psql -v ON_ERROR_STOP=1 -f tests/01_reservas.sql   (cualquier fallo aborta con el nombre del test)
\set QUIET on
\pset tuples_only on

create or replace function pg_temp.ok(p_label text, p_cond boolean, p_info jsonb default null) returns void
language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'FALLA: % → %', p_label, coalesce(p_info::text, 'null');
  end if;
  raise notice 'ok  %', p_label;
end $$;

-- Atajos: llamar a una herramienta como lo haría n8n
create or replace function pg_temp.pelu(p_tool text, p_args jsonb, p_from text default '+34600111222', p_call text default null)
returns jsonb language sql as $$ select public.fn_tool_dispatch('+34983000001', p_from, p_call, p_tool, p_args) $$;
create or replace function pg_temp.rest(p_tool text, p_args jsonb, p_from text default '+34600999888', p_call text default null)
returns jsonb language sql as $$ select public.fn_tool_dispatch('+34983000002', p_from, p_call, p_tool, p_args) $$;

-- Fechas relativas (siempre en el futuro): el lunes de dentro de ≥ 8 días, y días de esa semana
select (current_date + 8 + ((8 - extract(isodow from current_date + 8)::int) % 7))::text as lunes \gset
select (:'lunes'::date + 1)::text as martes, (:'lunes'::date + 5)::text as sabado, (:'lunes'::date + 6)::text as domingo,
       (:'lunes'::date + 7)::text as lunes2, (current_date - 1)::text as ayer \gset

-- Que un festivo real no caiga en la semana de prueba (los tests de festivos lo insertan a propósito)
delete from public.holidays where fecha between :'lunes'::date and :'lunes2'::date;

\echo '── check_availability'
select pg_temp.ok('disponible lunes 10:00',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00')))->>'codigo' = 'DISPONIBLE');
select pg_temp.ok('hora_fin calculada por el backend (45 min)',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00')))->>'hora_fin' = '10:45');
select pg_temp.ok('sinónimo con tilde/mayúsculas: "Babylights" → mechas',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','Babylights','fecha',:'lunes','hora','10:00')))#>>'{servicio,codigo}' = 'mechas');
select pg_temp.ok('nombre parcial: "lavar" → peinado',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','lavar','fecha',:'lunes','hora','10:00')))#>>'{servicio,codigo}' = 'peinado');
select pg_temp.ok('servicio inexistente',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','manicura','fecha',:'lunes','hora','10:00')))->>'codigo' = 'SERVICIO_NO_ENCONTRADO');
select pg_temp.ok('sin servicio',
  (pg_temp.pelu('check_availability', jsonb_build_object('fecha',:'lunes','hora','10:00')))->>'codigo' = 'FALTA_SERVICIO');
select pg_temp.ok('domingo → DIA_CERRADO con próximo disponible',
  (select r->>'codigo' = 'DIA_CERRADO' and r ? 'proximo_disponible'
   from pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'domingo','hora','10:00')) r));
select pg_temp.ok('14:30 (hueco de mediodía) → FUERA_DE_HORARIO',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','14:30')))->>'codigo' = 'FUERA_DE_HORARIO');
select pg_temp.ok('13:30 + 45 min acaba 14:15 → FUERA_DE_HORARIO',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','13:30')))->>'codigo' = 'FUERA_DE_HORARIO');
select pg_temp.ok('13:15 + 45 min acaba 14:00 justo → DISPONIBLE',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','13:15')))->>'codigo' = 'DISPONIBLE');
select pg_temp.ok('ayer → FECHA_PASADA',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'ayer','hora','10:00')))->>'codigo' = 'FECHA_PASADA');
select pg_temp.ok('a 200 días → DEMASIADO_LEJOS',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',(current_date + 200)::text,'hora','10:00')))->>'codigo' = 'DEMASIADO_LEJOS');
select pg_temp.ok('fecha mal formada → ERROR_DATOS campo fecha',
  (select r->>'codigo' = 'ERROR_DATOS' and r->>'campo' = 'fecha'
   from pg_temp.pelu('check_availability', '{"servicio":"corte_mujer","fecha":"el lunes","hora":"10:00"}') r));
select pg_temp.ok('hora mal formada → ERROR_DATOS campo hora',
  (select r->>'codigo' = 'ERROR_DATOS' and r->>'campo' = 'hora'
   from pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','25:00')) r));
select pg_temp.ok('Marta no trabaja el sábado',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'sabado','hora','10:00','profesional','Marta')))->>'codigo' = 'OCUPADO');
select pg_temp.ok('Marta no hace mechas',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','mechas','fecha',:'lunes','hora','10:00','profesional','marta')))->>'codigo' = 'PROFESIONAL_NO_REALIZA_SERVICIO');
select pg_temp.ok('profesional inexistente',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00','profesional','Pepe')))->>'codigo' = 'PROFESIONAL_NO_ENCONTRADO');

\echo '── festivos y cierres'
insert into public.holidays (zona, fecha, nombre) values ('valladolid', :'martes', 'Festivo de prueba');
select pg_temp.ok('festivo → DIA_BLOQUEADO',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'martes','hora','10:00')))->>'codigo' = 'DIA_BLOQUEADO');
select pg_temp.ok('slots: el festivo no aparece',
  (select not exists (select 1 from jsonb_array_elements(r->'dias') d where d->>'fecha' = :'martes')
   from pg_temp.pelu('get_available_slots', jsonb_build_object('servicio','corte_mujer','fecha_inicio',:'lunes','fecha_fin',:'sabado')) r));
delete from public.holidays where nombre = 'Festivo de prueba';
select public.fn_add_closure_days('11111111-1111-1111-1111-111111111111', :'martes'::date, :'martes'::date, 'Formación');
select pg_temp.ok('cierre de día completo → DIA_BLOQUEADO',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'martes','hora','17:00')))->>'codigo' = 'DIA_BLOQUEADO');
delete from public.closures;

\echo '── create_appointment + doble comprobación'
select pg_temp.ok('crear cita 1 (lunes 10:00, cualquiera)',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00','nombre','Ana García'),
                '+34600000101', 'call-1'))->>'codigo' = 'CONFIRMADO');
select pg_temp.ok('reintento idéntico de Retell (misma llamada) → misma cita, repetida=true',
  (select r->>'codigo' = 'CONFIRMADO' and (r->>'repetida')::boolean
          and r->>'referencia' = (select referencia from public.appointments where call_id = 'call-1')
   from pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00','nombre','Ana García'),
                     '+34600000101', 'call-1') r));
select pg_temp.ok('solo 1 cita tras el reintento', (select count(*) = 1 from public.appointments where call_id = 'call-1'));
select pg_temp.ok('crear cita 2 misma hora → la otra profesional',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00','nombre','Bea'),
                '+34600000102', 'call-2'))->>'codigo' = 'CONFIRMADO');
select pg_temp.ok('las dos citas tienen profesionales distintas',
  (select count(distinct resource_id) = 2 from public.appointments where call_id in ('call-1','call-2')));
select pg_temp.ok('1ª comprobación ahora → OCUPADO con alternativas',
  (select r->>'codigo' = 'OCUPADO' and jsonb_array_length(r->'alternativas') between 1 and 3
   from pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00')) r));
select pg_temp.ok('3ª cita a la misma hora → ERROR_OCUPADO (2ª comprobación)',
  (select r->>'codigo' = 'ERROR_OCUPADO' and r ? 'alternativas'
   from pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:15','nombre','Carla'),
                     '+34600000103', 'call-3') r));
select pg_temp.ok('solape parcial también bloqueado (10:30 con citas hasta 10:45)',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','10:30')))->>'codigo' = 'OCUPADO');
select pg_temp.ok('10:45 ya está libre (rango semiabierto)',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','10:45')))->>'codigo' = 'DISPONIBLE');
select pg_temp.ok('margen de limpieza: tinte 16:00 (90+15) bloquea a Laura hasta 17:45',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','tinte','fecha',:'lunes','hora','16:00','nombre','Dora'),
                '+34600000104', 'call-4'))->>'codigo' = 'CONFIRMADO'
  and (pg_temp.pelu('check_availability', jsonb_build_object('servicio','mechas','fecha',:'lunes','hora','17:30')))->>'codigo' = 'OCUPADO'
  and (pg_temp.pelu('check_availability', jsonb_build_object('servicio','peinado','fecha',:'lunes','hora','17:30','profesional','Laura')))->>'codigo' = 'OCUPADO'
  and (pg_temp.pelu('check_availability', jsonb_build_object('servicio','peinado','fecha',:'lunes','hora','17:45','profesional','Laura')))->>'codigo' = 'DISPONIBLE');
select pg_temp.ok('slots reflejan las citas: la mañana del lunes ya no empieza a las 10:00',
  (select r->'dias'->0->'rangos'->0->>'desde' <> '10:00'
   from pg_temp.pelu('get_available_slots', jsonb_build_object('servicio','corte_mujer','fecha_inicio',:'lunes')) r));

\echo '── validación de datos de contacto'
select pg_temp.ok('teléfono español sin prefijo se normaliza',
  (select r->>'codigo' = 'CONFIRMADO' and r#>>'{cliente,telefono}' = '+34611222333'
   from pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','12:00','nombre','Eva','telefono','611 22 23 33'),
                     null, 'call-5') r));
select pg_temp.ok('número oculto y sin teléfono → FALTA_TELEFONO',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','12:30','nombre','Flor'), 'anonymous', 'call-6'))->>'codigo' = 'FALTA_TELEFONO');
select pg_temp.ok('email inválido → EMAIL_NO_VALIDO',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','12:30','nombre','Flor','email','flor arroba gmail'), '+34600000106', 'call-6'))->>'codigo' = 'EMAIL_NO_VALIDO');
select pg_temp.ok('sin nombre → NOMBRE_NO_VALIDO',
  (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','12:30'), '+34600000106', 'call-6'))->>'codigo' = 'NOMBRE_NO_VALIDO');
select (pg_temp.pelu('create_appointment', jsonb_build_object('servicio','corte_hombre','fecha',:'lunes','hora','12:30','nombre','Flor',
        'notas', E'hola\u0007\n' || repeat('x', 900)), '+34600000106', 'call-6'))->>'referencia' as ref_flor \gset
select pg_temp.ok('texto con caracteres de control se limpia y se recorta a 500',
  (select length(notas) = 500 and notas !~ '[[:cntrl:]]' from public.appointments a where a.referencia = :'ref_flor'));

\echo '── find / cancel / reschedule'
select pg_temp.ok('find por teléfono del llamante',
  (select r->>'codigo' = 'CITAS_ENCONTRADAS' and jsonb_array_length(r->'citas') = 1
   from pg_temp.pelu('find_appointments', '{}', '+34600000101') r));
select pg_temp.ok('find desde otro teléfono sin datos → SIN_CITAS',
  (pg_temp.pelu('find_appointments', '{}', '+34699999999'))->>'codigo' = 'SIN_CITAS');
select pg_temp.ok('find por nombre + fecha (número distinto)',
  (select r->>'codigo' = 'CITAS_ENCONTRADAS' and r->>'verificado_por' = 'nombre_fecha'
   from pg_temp.pelu('find_appointments', jsonb_build_object('nombre','ana','fecha',:'lunes'), '+34699999999') r));
select pg_temp.ok('find solo por nombre (sin fecha) no revela nada',
  (pg_temp.pelu('find_appointments', '{"nombre":"ana"}', '+34699999999'))->>'codigo' = 'SIN_CITAS');

select referencia as ref_ana, resource_id as res_ana from public.appointments where call_id = 'call-1' \gset
select pg_temp.ok('cancelar desde otro número y sin nombre → NO_VERIFICADA',
  (pg_temp.pelu('cancel_appointment', jsonb_build_object('referencia', :'ref_ana'), '+34699999999'))->>'codigo' = 'NO_VERIFICADA');
select pg_temp.ok('referencia inexistente → NO_ENCONTRADA',
  (pg_temp.pelu('cancel_appointment', '{"referencia":"000000"}', '+34600000101'))->>'codigo' in ('NO_ENCONTRADA'));
select pg_temp.ok('referencia dictada con espacios ("4 8 2 …") se entiende',
  (pg_temp.pelu('reschedule_appointment', jsonb_build_object('referencia', regexp_replace(:'ref_ana', '(.)', '\1 ', 'g'),
                'fecha', :'lunes', 'hora', '11:00'), '+34600000101'))->>'codigo' = 'REPROGRAMADA');
select pg_temp.ok('reprogramar mantiene la misma profesional si está libre',
  (select a.resource_id = :'res_ana'::uuid from public.appointments a where a.call_id = 'call-1'));
select pg_temp.ok('tras reprogramar, las 10:00 vuelven a tener hueco',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'lunes','hora','10:00')))->>'codigo' = 'DISPONIBLE');
select pg_temp.ok('reprogramar a hora ocupada → OCUPADO y la cita NO se mueve',
  (pg_temp.pelu('reschedule_appointment', jsonb_build_object('referencia', :'ref_ana', 'fecha', :'lunes', 'hora', '16:00',
                'servicio','mechas'), '+34600000101'))->>'codigo' = 'OCUPADO'
  and (select to_char(inicio at time zone 'Europe/Madrid', 'HH24:MI') = '11:00' from public.appointments where call_id = 'call-1'));
select pg_temp.ok('cancelar verificando por nombre (otro número)',
  (pg_temp.pelu('cancel_appointment', jsonb_build_object('referencia', :'ref_ana', 'nombre', 'Ana'), '+34699999999'))->>'codigo' = 'CANCELADA');
select pg_temp.ok('cancelar dos veces → NO_ENCONTRADA',
  (pg_temp.pelu('cancel_appointment', jsonb_build_object('referencia', :'ref_ana'), '+34600000101'))->>'codigo' = 'NO_ENCONTRADA');

-- Política de cancelación: una cita a menos de 12 h no se puede anular por teléfono
update public.tenants set antelacion_min_minutos = 0 where slug = 'peluqueria-demo';
insert into public.appointments (tenant_id, referencia, customer_id, nombre_cliente, service_id, resource_id, inicio, fin, fin_bloqueo)
select t.id, '999999', c.id, 'Gema', s.id, r.id, now() + interval '3 hours', now() + interval '3 hours 30 min', now() + interval '3 hours 30 min'
from public.tenants t
join public.customers c on c.tenant_id = t.id and c.telefono = '+34600000102'
join public.services s on s.tenant_id = t.id and s.codigo = 'corte_hombre'
join public.resources r on r.tenant_id = t.id and r.nombre = 'Laura'
where t.slug = 'peluqueria-demo';
select pg_temp.ok('cancelar con menos de 12 h → FUERA_DE_PLAZO',
  (pg_temp.pelu('cancel_appointment', '{"referencia":"999999"}', '+34600000102'))->>'codigo' = 'FUERA_DE_PLAZO');
update public.tenants set antelacion_min_minutos = 60 where slug = 'peluqueria-demo';

\echo '── restaurante (mesas con capacidad)'
select pg_temp.ok('restaurante: 4 comensales → mesa de 4',
  (select r->>'codigo' = 'CONFIRMADO' and r->>'profesional' in ('Mesa 3','Mesa 4')
   from pg_temp.rest('create_appointment', jsonb_build_object('servicio','cenar','fecha',:'martes','hora','21:00','nombre','Hugo','comensales','4'),
                     '+34600000201', 'r-1') r));
select pg_temp.ok('restaurante: 2 comensales → mesa de 2 (no desperdicia una de 4)',
  (select r->>'profesional' in ('Mesa 1','Mesa 2')
   from pg_temp.rest('create_appointment', jsonb_build_object('servicio','mesa','fecha',:'martes','hora','21:00','nombre','Iris','comensales',2),
                     '+34600000202', 'r-2') r));
select pg_temp.ok('restaurante: 7 comensales (máx. 8, mesa mayor 6) → CAPACIDAD_EXCEDIDA',
  (pg_temp.rest('check_availability', jsonb_build_object('servicio','mesa','fecha',:'martes','hora','21:00','comensales',7)))->>'codigo' = 'CAPACIDAD_EXCEDIDA');
select pg_temp.ok('restaurante: 12 comensales → GRUPO_GRANDE',
  (pg_temp.rest('check_availability', jsonb_build_object('servicio','mesa','fecha',:'martes','hora','21:00','comensales',12)))->>'codigo' = 'GRUPO_GRANDE');
select pg_temp.ok('restaurante: lunes cerrado',
  (pg_temp.rest('check_availability', jsonb_build_object('servicio','mesa','fecha',:'lunes','hora','21:00')))->>'codigo' = 'DIA_CERRADO');
select pg_temp.ok('restaurante: 22:30 + 90 min pasa del cierre → FUERA_DE_HORARIO',
  (pg_temp.rest('check_availability', jsonb_build_object('servicio','mesa','fecha',:'martes','hora','22:30')))->>'codigo' = 'FUERA_DE_HORARIO');
select pg_temp.ok('restaurante: franja "mañana" solo devuelve comidas',
  (select bool_and((rg->>'hasta')::time < '14:00'::time)
   from pg_temp.rest('get_available_slots', jsonb_build_object('servicio','mesa','fecha_inicio',:'martes','franja','mañana')) r,
        jsonb_array_elements(r->'dias'->0->'rangos') rg));

\echo '── aislamiento multi-tenant'
select pg_temp.ok('un servicio de otro negocio no existe aquí',
  (pg_temp.rest('check_availability', jsonb_build_object('servicio','corte_mujer','fecha',:'martes','hora','14:00')))->>'codigo' = 'SERVICIO_NO_ENCONTRADO');
select pg_temp.ok('una referencia de la peluquería no existe en el restaurante',
  (select (pg_temp.rest('cancel_appointment', jsonb_build_object('referencia', referencia), '+34600000102'))->>'codigo' = 'NO_ENCONTRADA'
   from public.appointments where call_id = 'call-2'));
select pg_temp.ok('número no asignado → ERROR_TECNICO',
  (public.fn_tool_dispatch('+34983999999', '+34600000101', 'x', 'check_availability', '{}'))->>'codigo' = 'ERROR_TECNICO');
select pg_temp.ok('… y queda en error_log para avisar a Verantia',
  exists (select 1 from public.error_log where codigo = 'NUMERO_NO_ASIGNADO'));
select pg_temp.ok('herramienta desconocida',
  (pg_temp.pelu('borrar_todo', '{}'))->>'codigo' = 'HERRAMIENTA_DESCONOCIDA');
select pg_temp.ok('args no es un objeto → no revienta',
  (public.fn_tool_dispatch('+34983000001', null, null, 'check_availability', '"hola"'::jsonb))->>'codigo' = 'FALTA_SERVICIO');
select pg_temp.ok('intento de inyección en el nombre del servicio',
  (pg_temp.pelu('check_availability', jsonb_build_object('servicio',$$x'; drop table appointments; --$$,'fecha',:'lunes','hora','10:00')))->>'codigo' = 'SERVICIO_NO_ENCONTRADO'
  and to_regclass('public.appointments') is not null);

\echo '── restricción de base de datos (última red)'
do $$
begin
  insert into public.appointments (tenant_id, referencia, nombre_cliente, service_id, resource_id, inicio, fin, fin_bloqueo)
  select a.tenant_id, '123123', 'Intruso', a.service_id, a.resource_id, a.inicio + interval '5 min', a.fin, a.fin
  from public.appointments a where a.call_id = 'call-2';
  raise exception 'FALLA: la BD permitió una cita solapada';
exception when exclusion_violation then
  raise notice 'ok  inserción directa solapada rechazada por citas_sin_solape';
end $$;

\echo '── contexto de inicio de llamada y fin de llamada'
select pg_temp.ok('contexto: negocio, servicios, horario, FAQs',
  (select r->>'ok' = 'true' and jsonb_array_length(r->'servicios') = 5 and jsonb_array_length(r->'horario') = 6
          and jsonb_array_length(r->'faqs') = 2 and jsonb_typeof(r->'cliente') = 'null'
   from public.fn_tenant_context('+34983000001', 'anonymous') r));
select pg_temp.ok('contexto: cliente conocido con sus citas',
  (select r#>>'{cliente,nombre}' = 'Bea' and jsonb_array_length(r#>'{cliente,citas}') >= 1
   from public.fn_tenant_context('+34 983 000 001', '600000102') r));
select pg_temp.ok('contexto: número desconocido',
  (public.fn_tenant_context('+34983999999'))->>'codigo' = 'NUMERO_NO_ASIGNADO');
select pg_temp.ok('derivación → DERIVACION_REGISTRADA',
  (select r->>'codigo' = 'DERIVACION_REGISTRADA' and r ? 'transferencia_disponible'
   from pg_temp.pelu('escalate_to_human', '{"motivo":"queja","resumen":"Cliente molesto por un retraso"}', '+34600000101', 'call-9') r));
select pg_temp.ok('… y queda marcada en calls', exists (select 1 from public.calls where call_id = 'call-9' and escalada));
select pg_temp.ok('fin de llamada: sin transcripción si el negocio no la activa',
  (select r->>'ok' = 'true' and (r->>'escalada')::boolean
   from public.fn_log_call(jsonb_build_object('call_id','call-9','to_number','+34983000001','from_number','+34600000101',
        'start_timestamp', (extract(epoch from now() - interval '3 min') * 1000)::bigint::text,
        'end_timestamp', (extract(epoch from now()) * 1000)::bigint::text, 'transcripcion','bla bla', 'resultado','derivada')) r));
select pg_temp.ok('… duración guardada y transcripción descartada',
  (select transcripcion is null and duracion_seg between 170 and 190 from public.calls where call_id = 'call-9'));

\echo '── RGPD'
update public.calls set transcripcion = 'x', transcripcion_expira_at = now() - interval '1 day' where call_id = 'call-9';
select pg_temp.ok('purga de transcripciones caducadas',
  ((public.fn_purge_expired())->>'transcripciones_borradas')::int = 1);
select pg_temp.ok('derecho de supresión',
  (select (r->>'citas_anonimizadas')::int >= 1 from public.fn_forget_customer('11111111-1111-1111-1111-111111111111', '+34600000102') r));
select pg_temp.ok('… cliente borrado y citas anonimizadas',
  not exists (select 1 from public.customers where telefono = '+34600000102')
  and exists (select 1 from public.appointments where call_id = 'call-2' and nombre_cliente = '[suprimido]' and customer_id is null));

\echo '── permisos (anon / authenticated no pueden nada)'
set role anon;
do $$ begin
  perform 1 from public.appointments;
  raise exception 'FALLA: anon puede leer citas';
exception when insufficient_privilege then raise notice 'ok  anon no puede leer tablas';
end $$;
do $$ begin
  perform public.fn_tool_dispatch('+34983000001', null, null, 'find_appointments', '{}');
  raise exception 'FALLA: anon puede ejecutar fn_tool_dispatch';
exception when insufficient_privilege then raise notice 'ok  anon no puede ejecutar funciones';
end $$;
reset role;
set role service_role;
select pg_temp.ok('service_role (n8n) sí puede',
  (public.fn_tool_dispatch('+34983000001', null, null, 'check_availability', '{}'))->>'codigo' = 'FALTA_SERVICIO');
reset role;

\echo '══ TODOS LOS TESTS FUNCIONALES OK'
