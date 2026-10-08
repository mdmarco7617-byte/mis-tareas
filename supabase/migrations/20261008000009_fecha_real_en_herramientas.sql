-- 009 · La fecha real viaja en cada respuesta de herramienta
-- Motivo: en pruebas desde el panel de Retell la fecha del agente viene de variables fijas
-- y puede quedarse vieja; el agente calculaba "mañana" mal y la agenda respondía FECHA_PASADA.
-- Con el campo "hoy" en cada respuesta, el agente siempre puede corregirse con la fecha del servidor.

create or replace function public._hoy_texto(p_tenant uuid)
returns text
language sql stable set search_path = public as $$
  select format('%s %s de %s de %s, son las %s (%s)',
           public._dia_es(l::date), extract(day from l)::int,
           (array['enero','febrero','marzo','abril','mayo','junio','julio','agosto',
                  'septiembre','octubre','noviembre','diciembre'])[extract(month from l)::int],
           extract(year from l)::int, to_char(l, 'HH24:MI'), to_char(l, 'YYYY-MM-DD'))
  from (select now() at time zone t.zona_horaria as l from public.tenants t where t.id = p_tenant) x
$$;

create or replace function public.fn_voz_tool(
  p_raw text, p_signature text,
  p_tool text default null, p_to text default null, p_from text default null, p_call_id text default null)
returns jsonb
language plpgsql volatile set search_path = public, extensions as $$
declare
  b jsonb; v_tool text; v_args jsonb; v_to text; v_from text; v_call text;
  r jsonb; v_cod text; v_notif jsonb; v_priv text; v_agente jsonb;
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

  -- La fecha real del negocio va en cada respuesta: si el agente arrastra una fecha
  -- equivocada (p. ej. variables de prueba de otro día), la herramienta se la corrige.
  v_agente := public._solo_para_agente(r);
  if r ? 'tenant_id' then
    v_agente := v_agente || jsonb_build_object('hoy', public._hoy_texto((r->>'tenant_id')::uuid));
  end if;

  return jsonb_build_object('firma_valida', true, 'herramienta', v_tool,
                            'agente', v_agente, 'notificacion', v_notif,
                            'alerta', v_cod in ('ERROR_TECNICO','HERRAMIENTA_DESCONOCIDA'),
                            'tenant_id', r->>'tenant_id', 'call_id', v_call);
exception when others then
  insert into public.error_log (origen, codigo, detalle)
  values ('fn_voz_tool', sqlstate, jsonb_build_object('tool', v_tool, 'call_id', v_call, 'error', left(sqlerrm, 300)));
  return jsonb_build_object('firma_valida', true, 'agente', public._resp('ERROR_TECNICO'), 'notificacion', null,
                            'alerta', true, 'call_id', v_call);
end $$;

-- Solo el backend (service_role) puede ejecutarlas, igual que el resto de funciones fn_voz_*
revoke all on function public._hoy_texto(uuid) from public, anon, authenticated;
grant execute on function public._hoy_texto(uuid) to service_role;
