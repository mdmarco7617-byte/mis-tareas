#!/usr/bin/env bash
# Pruebas de la entrada firmada desde Retell (migración 005) y de las funciones RGPD.
# Las firmas se calculan con openssl, fuera de la base de datos, como lo haría Retell.
set -euo pipefail
DB=${DB:-verantia_test}
P="psql -U ${PGUSER:-postgres} -d $DB -Atq -v ON_ERROR_STOP=1"
KEY="key_de_prueba_$(date +%s)"
FAIL=0

$P -c "delete from vault.secretos_locales; insert into vault.secretos_locales values ('retell_api_key', '$KEY')"
LUNES=$($P -c "select current_date + 22 + ((8 - extract(isodow from current_date + 22)::int) % 7)")
$P -c "delete from holidays where fecha = '$LUNES'"

firmar() {  # $1=cuerpo $2=timestamp ms (opcional) → cabecera X-Retell-Signature
  local ts=${2:-$(($(date +%s%N) / 1000000))}
  local d; d=$(printf '%s%s' "$1" "$ts" | openssl dgst -sha256 -hmac "$KEY" -r | cut -d' ' -f1)
  echo "v=$ts,d=$d"
}
sql() {  # $1=consulta con :'raw' y :'sig'; $2=cuerpo; $3=firma
  printf '%s\n' "$1" | $P -v raw="$2" -v sig="$3"
}
ok() {  # $1=etiqueta $2=valor $3=esperado
  if [[ "$2" == "$3" ]]; then echo "ok  $1"; else echo "FALLA  $1 → obtenido '$2', esperado '$3'"; FAIL=1; fi
}

echo "── inicio de llamada (call_inbound)"
IN='{"event":"call_inbound","call_inbound":{"call_id":"c-firma-1","agent_id":"a1","from_number":"+34600777001","to_number":"+34983000001"}}'
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'ok'" "$IN" "$(firmar "$IN")");                ok "firma válida → contexto del negocio" "$R" "true"
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'numero_negocio'" "$IN" "$(firmar "$IN")");    ok "devuelve el número del negocio normalizado" "$R" "+34983000001"
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'codigo'" "$IN" "v=123,d=abc");                ok "firma basura → FIRMA_NO_VALIDA" "$R" "FIRMA_NO_VALIDA"
VIEJO=$(( $(date +%s%N) / 1000000 - 6 * 60 * 1000 ))
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'codigo'" "$IN" "$(firmar "$IN" $VIEJO)");     ok "firma de hace 6 min (replay) → FIRMA_NO_VALIDA" "$R" "FIRMA_NO_VALIDA"
OTRO='{"event":"call_inbound","call_inbound":{"call_id":"c-x","from_number":"+34600777001","to_number":"+34983000002"}}'
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'codigo'" "$OTRO" "$(firmar "$IN")");          ok "cuerpo manipulado (firma de otro cuerpo) → FIRMA_NO_VALIDA" "$R" "FIRMA_NO_VALIDA"
DESC='{"event":"call_inbound","call_inbound":{"call_id":"c-y","from_number":"+34600777001","to_number":"+34983999999"}}'
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'codigo'" "$DESC" "$(firmar "$DESC")");        ok "número no asignado → NUMERO_NO_ASIGNADO" "$R" "NUMERO_NO_ASIGNADO"

echo "── herramientas (custom functions)"
FULL="{\"name\":\"check_availability\",\"call\":{\"call_id\":\"c-firma-2\",\"from_number\":\"+34600777001\",\"to_number\":\"+34983000001\",\"transcript\":\"texto\"},\"args\":{\"servicio\":\"corte_mujer\",\"fecha\":\"$LUNES\",\"hora\":\"10:00\"}}"
R=$(sql "select fn_voz_tool(:'raw', :'sig')#>>'{agente,codigo}'" "$FULL" "$(firmar "$FULL")");  ok "formato completo → DISPONIBLE" "$R" "DISPONIBLE"
R=$(sql "select fn_voz_tool(:'raw', :'sig')#>>'{agente,hoy}' ~ ', son las [0-9]{2}:[0-9]{2} \\([0-9]{4}-[0-9]{2}-[0-9]{2}\\)$'" "$FULL" "$(firmar "$FULL")"); ok "la respuesta trae la fecha real del negocio (hoy)" "$R" "t"
R=$(sql "select (fn_voz_tool(:'raw', :'sig')->'notificacion') is null or (fn_voz_tool(:'raw', :'sig')->>'notificacion') is null" "$FULL" "$(firmar "$FULL")"); ok "consulta de disponibilidad no genera notificación" "$R" "t"

ARGS="{\"servicio\":\"corte_mujer\",\"fecha\":\"$LUNES\",\"hora\":\"11:00\",\"nombre\":\"Nuria Prueba\",\"email\":\"nuria@example.com\"}"
TOOL="select fn_voz_tool(:'raw', :'sig', 'create_appointment', '+34983000001', '+34600777001', 'c-firma-3')"
R=$(sql "select r#>>'{agente,codigo}' from ($TOOL) x(r)" "$ARGS" "$(firmar "$ARGS")");          ok "formato solo-argumentos + cabeceras → CONFIRMADO" "$R" "CONFIRMADO"
R=$(sql "select (r->'agente') ?| array['cliente','negocio','confirmacion','cita_id','tenant_id'] from ($TOOL) x(r)" "$ARGS" "$(firmar "$ARGS")")
ok "a la IA NO le llegan datos de contacto ni ids internos" "$R" "f"
R=$(sql "select r->'notificacion' from ($TOOL) x(r)" "$ARGS" "$(firmar "$ARGS")")
ok "reintento de Retell (misma cita) → sin segunda notificación" "$R" "null"
ARGS2="{\"servicio\":\"corte_hombre\",\"fecha\":\"$LUNES\",\"hora\":\"12:00\",\"nombre\":\"Oscar Prueba\"}"
TOOL2="select fn_voz_tool(:'raw', :'sig', 'create_appointment', '+34983000001', '+34600777002', 'c-firma-4')"
R=$(sql "select concat_ws('|', r#>>'{notificacion,tipo}', r#>>'{notificacion,cliente,telefono}', r#>>'{notificacion,negocio,whatsapp_avisos}') from ($TOOL2) x(r)" "$ARGS2" "$(firmar "$ARGS2")")
ok "la notificación sí lleva los datos para WhatsApp (cliente y negocio)" "$R" "cita_confirmada|+34600777002|+34600000001"
R=$(sql "select r->>'firma_valida' from ($TOOL) x(r)" "$ARGS2" "$(firmar "$ARGS")");            ok "argumentos cambiados tras firmar → rechazado" "$R" "false"

ESC='{"motivo":"cliente_lo_pide","resumen":"Quiere hablar con Laura sobre un tratamiento"}'
TOOL3="select fn_voz_tool(:'raw', :'sig', 'escalate_to_human', '+34983000001', '+34600777003', 'c-firma-5')"
R=$(sql "select concat_ws('|', r#>>'{notificacion,tipo}', r#>>'{notificacion,llamante}', r#>>'{agente,codigo}') from ($TOOL3) x(r)" "$ESC" "$(firmar "$ESC")")
ok "derivación → aviso al negocio con el teléfono para devolver la llamada" "$R" "derivacion|+34600777003|DERIVACION_REGISTRADA"

echo "── eventos de llamada"
EV='{"event":"call_started","call":{"call_id":"c-firma-6"}}'
R=$(sql "select fn_voz_event(:'raw', :'sig')->>'ignorado'" "$EV" "$(firmar "$EV")");            ok "call_started se ignora" "$R" "true"
T1=$(( $(date +%s%N) / 1000000 - 150000 )); T2=$(( $(date +%s%N) / 1000000 ))
EV2="{\"event\":\"call_analyzed\",\"call\":{\"call_id\":\"c-firma-7\",\"from_number\":\"+34600777004\",\"to_number\":\"+34983000001\",\"start_timestamp\":$T1,\"end_timestamp\":$T2,\"transcript\":\"Agente: hola...\",\"disconnection_reason\":\"user_hangup\",\"call_analysis\":{\"call_summary\":\"Preguntó por precios de mechas y colgó\",\"call_successful\":false}}}"
R=$(sql "select concat_ws('|', r->>'ok', r->>'avisar_negocio', r->>'llamante') from (select fn_voz_event(:'raw', :'sig')) x(r)" "$EV2" "$(firmar "$EV2")")
ok "call_analyzed no resuelta → aviso al negocio" "$R" "true|true|+34600777004"
R=$($P -c "select concat_ws('|', duracion_seg between 145 and 155, transcripcion is null, resultado) from calls where call_id = 'c-firma-7'")
ok "se guarda duración y resultado; la transcripción NO (el negocio no la activó)" "$R" "t|t|no_resuelta"
R=$(sql "select fn_voz_event(:'raw', :'sig')->>'avisar_negocio'" "$EV2" "$(firmar "$EV2")")
ok "evento reenviado por Retell → se actualiza sin duplicar" "$R" "true"
R=$($P -c "select count(*) from calls where call_id = 'c-firma-7'");                             ok "… una sola fila" "$R" "1"

echo "── RGPD"
R=$($P -c "select concat_ws('|', r#>>'{cliente,nombre}', jsonb_array_length(r->'citas')) from fn_export_customer('11111111-1111-1111-1111-111111111111', '600777002') r")
ok "derecho de acceso: exporta cliente y citas" "$R" "Oscar Prueba|1"
$P -c "update calls set created_at = now() - interval '100 days' where call_id = 'c-firma-7'"
$P -c "update appointments set inicio = now() - interval '26 months', fin = now() - interval '26 months' + interval '30 min', fin_bloqueo = now() - interval '26 months' + interval '30 min' where call_id = 'c-firma-4'"
$P -c "alter table customers disable trigger trg_customers_updated" \
   -c "update customers set updated_at = now() - interval '26 months' where telefono = '+34600777002'" \
   -c "alter table customers enable trigger trg_customers_updated"
R=$($P -c "select concat_ws('|', r->>'llamadas_anonimizadas', r->>'citas_anonimizadas', r->>'clientes_borrados') from fn_purge_expired() r")
ok "purga: llamada de 100 días, cita y cliente de 26 meses" "$R" "1|1|1"
R=$($P -c "select concat_ws('|', from_number is null, resumen is null, duracion_seg is not null) from calls where call_id = 'c-firma-7'")
ok "… la llamada conserva la duración (facturación) sin datos personales" "$R" "t|t|t"
R=$($P -c "select concat_ws('|', nombre_cliente, customer_id is null) from appointments where call_id = 'c-firma-4'")
ok "… la cita queda anonimizada" "$R" "[caducado]|t"

echo "── vigilancia y fallos"
R=$($P -c "set role service_role; select concat_ws('|', fn_voz_health()->>'ok', fn_voz_health()->>'purga_programada')" | tail -1)
ok "fn_voz_health como service_role (sin acceso al esquema cron) → ok y purga detectada" "$R" "true|true"
R=$($P -c "select (fn_voz_health()->>'ok')");                                                     ok "fn_voz_health responde" "$R" "true"
$P -c "delete from vault.secretos_locales"
R=$(sql "select fn_voz_inbound(:'raw', :'sig')->>'codigo'" "$IN" "$(firmar "$IN")");            ok "sin secreto en Vault → ERROR_TECNICO controlado (y queda registrado)" "$R" "ERROR_TECNICO"
R=$($P -c "select count(*) > 0 from error_log where detalle->>'error' like '%retell_api_key%'"); ok "… el error dice qué falta" "$R" "t"

[[ $FAIL == 0 ]] && echo "══ FIRMA Y RGPD OK" || { echo "══ FIRMA Y RGPD CON FALLOS"; exit 1; }
