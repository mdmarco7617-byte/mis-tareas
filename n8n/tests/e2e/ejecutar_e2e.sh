#!/usr/bin/env bash
# Prueba de extremo a extremo: n8n REAL con los 6 flujos importados, llamadas firmadas como las de
# Retell, base de datos REAL (Postgres local con las migraciones) y simuladores de WhatsApp/Twilio/SMTP.
# Requisitos: Postgres local con la BD de pruebas (supabase/tests/run_local.sh) y n8n instalado en $N8N_DIR.
set -uo pipefail
cd "$(dirname "$0")"
E2E=$(pwd); RAIZ=$(cd ../../.. && pwd)
N8N_DIR=${N8N_DIR:-/var/tmp/n8nprueba}; N8N="$N8N_DIR/node_modules/.bin/n8n"
TRABAJO=${TRABAJO:-/var/tmp/voz_e2e}; DB=${DB:-verantia_test}
export N8N_USER_FOLDER="$TRABAJO/n8n" N8N_PORT=5678 N8N_DIAGNOSTICS_ENABLED=false N8N_SECURE_COOKIE=false \
       N8N_ENCRYPTION_KEY=clave-cifrado-solo-pruebas N8N_LOG_LEVEL=warn N8N_PERSONALIZATION_ENABLED=false \
       GENERIC_TIMEZONE=Europe/Madrid N8N_LISTEN_ADDRESS=127.0.0.1
KEY="retell-clave-e2e"; BASE="http://127.0.0.1:5678/webhook/verantia-voz"
P="psql -U ${PGUSER:-postgres} -d $DB -Atq"
FAIL=0
ok() { if [[ "$2" == "$3" ]]; then echo "ok  $1"; else echo "FALLA  $1 → obtenido '$2', esperado '$3'"; FAIL=1; fi; }
firmar() { local ts=$(($(date +%s%N) / 1000000)); echo "v=$ts,d=$(printf '%s%s' "$1" "$ts" | openssl dgst -sha256 -hmac "$KEY" -r | cut -d' ' -f1)"; }
post() { curl -s -o "$TRABAJO/resp.json" -w '%{http_code}' -X POST "$BASE/$1" -H 'content-type: application/json' -H "x-retell-signature: $2" "${@:4}" --data-binary "$3"; }
jq_() { python3 -c "import json,re,sys; d=json.load(open('$1')); print(eval(sys.argv[1]))" "$2" 2>/dev/null; }
registro() { curl -s http://127.0.0.1:54322/registro > "$TRABAJO/registro.json"; jq_ "$TRABAJO/registro.json" "$1"; }

# ─── Preparación ───────────────────────────────────────────────────────────
rm -rf "$TRABAJO" && mkdir -p "$TRABAJO"
$P -c "delete from vault.secretos_locales; insert into vault.secretos_locales values ('retell_api_key', '$KEY'); delete from error_log;"
LUNES=$($P -c "select current_date + 36 + ((8 - extract(isodow from current_date + 36)::int) % 7)")
$P -c "delete from holidays where fecha = '$LUNES'"
VOZ_SALIDA="$TRABAJO/generados" VOZ_PRUEBAS='{"SUPABASE_URL":"http://127.0.0.1:54321","WHATSAPP_API_URL":"http://127.0.0.1:54322","TWILIO_API_URL":"http://127.0.0.1:54322","TWILIO_ACCOUNT_SID":"ACprueba","WHATSAPP_PHONE_NUMBER_ID":"123456","WHATSAPP_VERANTIA":"+34600000000"}' \
  python3 "$RAIZ/n8n/construir_flujos.py" > /dev/null
python3 preparar_import.py "$TRABAJO/generados" "$TRABAJO/importar/flujos"
ln -sfn "$N8N_DIR/node_modules" "$TRABAJO/node_modules"; cp simuladores.mjs "$TRABAJO/"
PGHOST=$PGHOST PGPORT=$PGPORT DB=$DB node "$TRABAJO/simuladores.mjs" > "$TRABAJO/simuladores.log" 2>&1 &
SIM=$!
"$N8N" import:credentials --input="$TRABAJO/importar/credenciales.json" > "$TRABAJO/import.log" 2>&1 || { cat "$TRABAJO/import.log"; exit 1; }
"$N8N" import:workflow --separate --input="$TRABAJO/importar/flujos" >> "$TRABAJO/import.log" 2>&1 || { cat "$TRABAJO/import.log"; exit 1; }
for id in vozInicio0000001 vozHerram0000002 vozFinLlam000003 vozNotif00000004 vozAlertas000005 vozVigila0000006; do
  "$N8N" publish:workflow --id=$id >> "$TRABAJO/import.log" 2>&1 || { echo "no se pudo publicar $id"; tail -5 "$TRABAJO/import.log"; exit 1; }
done
"$N8N" start > "$TRABAJO/n8n.log" 2>&1 &
N8NPID=$!
trap 'kill $N8NPID $SIM 2>/dev/null' EXIT
for i in $(seq 1 90); do curl -sf http://127.0.0.1:5678/healthz >/dev/null && break; sleep 1; done
for i in $(seq 1 20); do curl -s -o /dev/null -X POST http://127.0.0.1:54321/rest/v1/rpc/fn_voz_health -H "apikey: clave-prueba" -d "{}" && break; sleep 1; done
sleep 5
echo "── n8n $("$N8N" --version) arrancado con los 6 flujos"

# ─── 01 · Inicio de llamada ────────────────────────────────────────────────
B='{"event":"call_inbound","call_inbound":{"call_id":"e2e-1","agent_id":"a","from_number":"+34600555001","to_number":"+34983000001"}}'
ok "01 firma válida → 200" "$(post inicio "$(firmar "$B")" "$B")" "200"
ok "01 variables del negocio" "$(jq_ $TRABAJO/resp.json "d['call_inbound']['dynamic_variables']['nombre_negocio']")" "Peluquería Demo"
ok "01 todas las variables son texto" "$(jq_ $TRABAJO/resp.json "all(isinstance(v,str) for v in d['call_inbound']['dynamic_variables'].values())")" "True"
ok "01 saludo con aviso de IA" "$(jq_ $TRABAJO/resp.json "'inteligencia artificial' in d['call_inbound']['dynamic_variables']['saludo_inicial']")" "True"
ok "01 firma falsa → 401" "$(post inicio "v=1,d=00" "$B")" "401"
B2='{"event":"call_inbound","call_inbound":{"call_id":"e2e-2","from_number":"+34600555001","to_number":"+34983111222"}}'
ok "01 número no asignado → 200 en modo sin_sistema" "$(post inicio "$(firmar "$B2")" "$B2")|$(jq_ $TRABAJO/resp.json "d['call_inbound']['dynamic_variables']['modo_servicio']")" "200|sin_sistema"

# ─── 02 · Herramientas ─────────────────────────────────────────────────────
curl -s -X DELETE http://127.0.0.1:54322/registro > /dev/null
B="{\"name\":\"check_availability\",\"call\":{\"call_id\":\"e2e-3\",\"from_number\":\"+34600555001\",\"to_number\":\"+34983000001\"},\"args\":{\"servicio\":\"corte de mujer\",\"fecha\":\"$LUNES\",\"hora\":\"10:00\"}}"
ok "02 formato completo → DISPONIBLE" "$(post herramientas "$(firmar "$B")" "$B")|$(jq_ $TRABAJO/resp.json "d['codigo']")" "200|DISPONIBLE"
A="{\"servicio\":\"corte_mujer\",\"fecha\":\"$LUNES\",\"hora\":\"10:00\",\"nombre\":\"Elena E2E\",\"email\":\"elena@example.com\"}"
CAB=(-H 'x-herramienta: create_appointment' -H 'x-numero-negocio: +34983000001' -H 'x-numero-llamante: +34600555001' -H 'x-id-llamada: e2e-4')
ok "02 solo argumentos + cabeceras → CONFIRMADO" "$(post herramientas "$(firmar "$A")" "$A" "${CAB[@]}")|$(jq_ $TRABAJO/resp.json "d['codigo']")" "200|CONFIRMADO"
ok "02 a la IA no le llegan teléfono ni email" "$(jq_ $TRABAJO/resp.json "'cliente' in d or 'negocio' in d or 'elena@' in json.dumps(d)")" "False"
REF=$(jq_ $TRABAJO/resp.json "d['referencia']")
A2="{\"servicio\":\"mechas\",\"fecha\":\"$LUNES\",\"hora\":\"16:00\",\"nombre\":\"Sin WhatsApp\"}"
CAB2=(-H 'x-herramienta: create_appointment' -H 'x-numero-negocio: +34983000001' -H 'x-numero-llamante: +34600999999' -H 'x-id-llamada: e2e-5')
post herramientas "$(firmar "$A2")" "$A2" "${CAB2[@]}" > /dev/null
sleep 6
ok "04 WhatsApp de confirmación al cliente" "$(registro "sum(1 for m in d if m['canal']=='whatsapp' and m['plantilla']=='verantia_cita_confirmada' and m['to']=='34600555001' and m['parametros'][0]=='Elena E2E')")" "1"
ok "04 email al cliente" "$(registro "sum(1 for m in d if m['canal']=='email' and 'elena@example.com' in m['to'])")" "1"
ok "04 aviso al negocio (2 citas)" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_aviso_negocio' and m['to']=='34600000001' and m['parametros'][1]=='Nueva cita')")" "2"
ok "04 número sin WhatsApp → SMS de respaldo" "$(registro "sum(1 for m in d if m['canal']=='sms' and m['to']=='+34600999999' and 'Ref.' in m['texto'] and m['from']=='Verantia')")" "1"

A3="{\"referencia\":\"$REF\",\"fecha\":\"$LUNES\",\"hora\":\"12:00\"}"
CAB3=(-H 'x-herramienta: reschedule_appointment' -H 'x-numero-negocio: +34983000001' -H 'x-numero-llamante: +34600555001' -H 'x-id-llamada: e2e-6')
ok "02 reprogramar → REPROGRAMADA" "$(post herramientas "$(firmar "$A3")" "$A3" "${CAB3[@]}")|$(jq_ $TRABAJO/resp.json "d['codigo']")" "200|REPROGRAMADA"
A4='{"motivo":"cliente_lo_pide","resumen":"Quiere hablar con Laura"}'
CAB4=(-H 'x-herramienta: escalate_to_human' -H 'x-numero-negocio: +34983000001' -H 'x-numero-llamante: +34600555002' -H 'x-id-llamada: e2e-7')
ok "02 derivar → DERIVACION_REGISTRADA" "$(post herramientas "$(firmar "$A4")" "$A4" "${CAB4[@]}")|$(jq_ $TRABAJO/resp.json "d['codigo']")" "200|DERIVACION_REGISTRADA"
ok "02 firma falsa → 401" "$(post herramientas "v=1,d=00" "$A" "${CAB[@]}")" "401"
CAB5=(-H 'x-herramienta: check_availability' -H 'x-numero-negocio: +34983000001' -H 'x-numero-llamante: +34600555001' -H 'x-id-llamada: forzar-caida')
ok "02 Supabase caído → el agente recibe ERROR_TECNICO (nunca silencio)" "$(post herramientas "$(firmar "$A")" "$A" "${CAB5[@]}")|$(jq_ $TRABAJO/resp.json "d['codigo']")" "200|ERROR_TECNICO"
sleep 6
ok "04 cambio de cita → WhatsApp de modificación al cliente" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_cita_modificada' and m['to']=='34600555001')")" "1"
ok "04 derivación → aviso al negocio con el teléfono" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_aviso_negocio' and m['parametros'][1]=='Llamada para el equipo' and '+34600555002' in m['parametros'][3])")" "1"
ok "05 alerta a Verantia por el número no asignado" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_alerta_tecnica' and 'NUMERO_NO_ASIGNADO' in m['parametros'][1])")" "1"
ok "05 alerta a Verantia por Supabase caído" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_alerta_tecnica' and m['parametros'][1]=='SUPABASE_NO_RESPONDE')")" "1"
ok "05 las alertas no llevan teléfonos ni emails" "$(registro "any(re.search(r'\\d{9,}|@', ' '.join(m['parametros'])) for m in d if m.get('plantilla')=='verantia_alerta_tecnica')")" "False"

# ─── 03 · Fin de llamada ───────────────────────────────────────────────────
curl -s -X DELETE http://127.0.0.1:54322/registro > /dev/null
T2=$(($(date +%s%N) / 1000000)); T1=$((T2 - 120000))
E="{\"event\":\"call_analyzed\",\"call\":{\"call_id\":\"e2e-8\",\"from_number\":\"+34600555003\",\"to_number\":\"+34983000001\",\"start_timestamp\":$T1,\"end_timestamp\":$T2,\"transcript\":\"...\",\"call_analysis\":{\"call_summary\":\"Preguntó si abren el domingo y colgó\",\"call_successful\":false}}}"
ok "03 call_analyzed → 200 inmediato" "$(post eventos "$(firmar "$E")" "$E")" "200"
E2='{"event":"call_started","call":{"call_id":"e2e-9"}}'
ok "03 call_started → 200 y se ignora" "$(post eventos "$(firmar "$E2")" "$E2")" "200"
sleep 6
ok "03 llamada guardada: 120 s, sin transcripción" "$($P -c "select duracion_seg || '|' || (transcripcion is null) from calls where call_id = 'e2e-8'")" "120|true"
ok "04 llamada no resuelta → aviso al negocio" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_aviso_negocio' and m['parametros'][1]=='Llamada no resuelta' and '+34600555003' in m['parametros'][3])")" "1"
ok "03 call_started no genera nada" "$($P -c "select count(*) from calls where call_id = 'e2e-9'")" "0"

# ─── 06 · Vigilancia diaria ────────────────────────────────────────────────
curl -s -X DELETE http://127.0.0.1:54322/registro > /dev/null
kill $N8NPID 2>/dev/null; wait $N8NPID 2>/dev/null; sleep 2   # el CLI no puede ejecutar con otro n8n en marcha
timeout 120 "$N8N" execute --id=vozVigila0000006 > "$TRABAJO/vigilancia.log" 2>&1
sleep 4
ok "06 revisión diaria detecta los errores del día y avisa" "$(registro "sum(1 for m in d if m.get('plantilla')=='verantia_alerta_tecnica' and m['parametros'][1]=='REVISION_DIARIA')")" "1"

# ─── RGPD en n8n ───────────────────────────────────────────────────────────
N_EJEC=$(python3 -c "import sqlite3; print(sqlite3.connect('$N8N_USER_FOLDER/.n8n/database.sqlite').execute(\"select count(*) from execution_entity where status = 'success'\").fetchone()[0])" 2>/dev/null || echo "?")
N_DATOS=$(python3 -c "import sqlite3; print(sqlite3.connect('$N8N_USER_FOLDER/.n8n/database.sqlite').execute(\"select count(*) from execution_data d join execution_entity e on e.id = d.executionId where e.status = 'success'\").fetchone()[0])" 2>/dev/null || echo "?")
ok "RGPD: n8n no guarda datos de las ejecuciones correctas" "$N_DATOS" "0"
echo "   (ejecuciones correctas registradas sin datos: $N_EJEC)"
ERRS=$(grep -ciE "error|problem" "$TRABAJO/n8n.log" || true)
echo "   (líneas de error en el log de n8n: $ERRS · $TRABAJO/n8n.log)"

[[ $FAIL == 0 ]] && echo "══ E2E n8n OK" || { echo "══ E2E CON FALLOS"; exit 1; }
