-- Verantia Voice · 008 · Idempotencia por persona
-- Antes la clave de "petición repetida" no incluía el nombre: dos personas distintas reservando lo mismo
-- desde el mismo móvil y en la misma llamada (p. ej. una madre con dos hijos) se confundían, y la segunda
-- reserva se descartaba devolviendo "CONFIRMADO" con la referencia de la primera.
-- Ahora la clave incluye el nombre (normalizado): solo es "repetida" la misma persona, mismo servicio, día y hora.
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
                        coalesce(public.fn_normalize_phone(g->>'telefono'), v_from),
                        coalesce(public._norm(g->>'nombre'), ''))) end)
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

revoke all on function public.fn_tool_dispatch(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.fn_tool_dispatch(text, text, text, text, jsonb) to service_role;
