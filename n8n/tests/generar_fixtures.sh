#!/usr/bin/env bash
# Genera respuestas REALES de las funciones de Supabase (sobre la BD local de pruebas) para
# alimentar las pruebas del código de n8n. Así el JS se prueba con la forma exacta de los datos.
# Uso: PGHOST=... PGPORT=... DB=verantia_test ./n8n/tests/generar_fixtures.sh
set -euo pipefail
cd "$(dirname "$0")"
DB=${DB:-verantia_test}
P="psql -U ${PGUSER:-postgres} -d $DB -Atq -v ON_ERROR_STOP=1"
KEY="key_fixtures"
OUT=fixtures; mkdir -p $OUT

$P -c "delete from vault.secretos_locales; insert into vault.secretos_locales values ('retell_api_key', '$KEY')"
LUNES=$($P -c "select current_date + 29 + ((8 - extract(isodow from current_date + 29)::int) % 7)")
$P -c "delete from holidays where fecha between '$LUNES'::date and '$LUNES'::date + 1"

firmar() { local ts=$(($(date +%s%N) / 1000000)); echo "v=$ts,d=$(printf '%s%s' "$1" "$ts" | openssl dgst -sha256 -hmac "$KEY" -r | cut -d' ' -f1)"; }
q() { printf '%s\n' "$1" | $P -v raw="$2" -v sig="$(firmar "$2")"; }
tool() {  # $1=herramienta $2=args $3=llamante $4=call_id
  q "select fn_voz_tool(:'raw', :'sig', '$1', '+34983000001', '$3', '$4')" "$2"
}

tool create_appointment "{\"servicio\":\"corte_mujer\",\"fecha\":\"$LUNES\",\"hora\":\"10:00\",\"nombre\":\"Ana Fixture\",\"email\":\"ana@example.com\"}" +34600888001 fx-1 > $OUT/tool_confirmado.json
REF=$($P -c "select referencia from appointments where call_id = 'fx-1'")
IN='{"event":"call_inbound","call_inbound":{"call_id":"fx-in","from_number":"+34600888001","to_number":"+34983000001"}}'
q "select fn_voz_inbound(:'raw', :'sig')" "$IN" > $OUT/contexto_ok.json
IN2='{"event":"call_inbound","call_inbound":{"call_id":"fx-in2","from_number":"+34600888001","to_number":"+34983999999"}}'
q "select fn_voz_inbound(:'raw', :'sig')" "$IN2" > $OUT/contexto_desconocido.json
q "select fn_voz_inbound(:'raw', :'sig')" "$IN" | sed 's/.*/{"ok": false, "codigo": "FIRMA_NO_VALIDA"}/' > $OUT/contexto_firma_mala.json
tool reschedule_appointment "{\"referencia\":\"$REF\",\"fecha\":\"$LUNES\",\"hora\":\"11:00\"}" +34600888001 fx-2 > $OUT/tool_reprogramada.json
tool cancel_appointment "{\"referencia\":\"$REF\"}" +34600888001 fx-3 > $OUT/tool_cancelada.json
tool escalate_to_human '{"motivo":"queja","resumen":"Cliente molesto por un retraso de ayer"}' +34600888002 fx-4 > $OUT/tool_derivacion.json
tool check_availability "{\"servicio\":\"corte_mujer\",\"fecha\":\"$LUNES\",\"hora\":\"10:00\"}" +34600888001 fx-5 > $OUT/tool_disponible.json
T2=$(($(date +%s%N) / 1000000)); T1=$((T2 - 95000))
EV="{\"event\":\"call_analyzed\",\"call\":{\"call_id\":\"fx-ev\",\"from_number\":\"+34600888003\",\"to_number\":\"+34983000001\",\"start_timestamp\":$T1,\"end_timestamp\":$T2,\"transcript\":\"...\",\"call_analysis\":{\"call_summary\":\"Preguntó el precio de las mechas y quería saber si hay parking.\",\"call_successful\":false}}}"
q "select fn_voz_event(:'raw', :'sig')" "$EV" > $OUT/evento_no_resuelta.json
$P -c "select fn_voz_health()" > $OUT/salud.json
echo "fixtures generadas en n8n/tests/$OUT: $(ls $OUT | tr '\n' ' ')"
