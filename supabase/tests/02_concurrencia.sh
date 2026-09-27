#!/usr/bin/env bash
# Prueba de concurrencia REAL: N conexiones simultáneas intentan reservar el mismo hueco.
# Demuestra que la doble comprobación + bloqueo + restricción de exclusión impiden el doble booking.
# Uso: DB=verantia PGHOST=... PGPORT=... ./supabase/tests/02_concurrencia.sh
set -euo pipefail
DB=${DB:-verantia_test}
N=${N:-20}
P="psql -U ${PGUSER:-postgres} -d $DB -Atq -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
FAIL=0

# Un lunes a ≥ 15 días vista (no coincide con los datos de los tests funcionales)
FECHA=$($P -c "select current_date + 15 + ((8 - extract(isodow from current_date + 15)::int) % 7)")
$P -c "delete from holidays where fecha = '$FECHA'"

lanzar() {  # $1=etiqueta $2=servicio $3=hora
  rm -f "$TMP"/"$1".*
  for i in $(seq 1 "$N"); do
    $P -c "select fn_tool_dispatch('+34983000001', '+346000$(printf %05d $i)', '$1-$i', 'create_appointment',
             '{\"servicio\":\"$2\",\"fecha\":\"$FECHA\",\"hora\":\"$3\",\"nombre\":\"Cliente $i\"}')->>'codigo'" > "$TMP/$1.$i" 2>&1 &
  done
  wait
}

comprobar() {  # $1=etiqueta $2=confirmadas esperadas
  local ok ocup otros
  ok=$(cat "$TMP"/"$1".* | grep -c '^CONFIRMADO$' || true)
  ocup=$(cat "$TMP"/"$1".* | grep -c '^ERROR_OCUPADO$' || true)
  otros=$((N - ok - ocup))
  if [[ "$ok" == "$2" && "$otros" == 0 ]]; then
    echo "ok  $1: $N llamadas simultáneas → $ok confirmada(s), $ocup ERROR_OCUPADO"
  else
    echo "FALLA  $1: confirmadas=$ok (esperadas $2), ocupado=$ocup, otros=$otros"; cat "$TMP"/"$1".* | sort | uniq -c; FAIL=1
  fi
}

echo "── concurrencia ($N conexiones a la vez, fecha $FECHA)"

# A) Mechas: solo Laura las hace → exactamente 1 cita
lanzar mechas mechas 10:00
comprobar mechas 1

# B) Corte de mujer a las 17:00: Laura y Marta → exactamente 2 citas, una por profesional
lanzar corte corte_mujer 17:00
comprobar corte 2
DIST=$($P -c "select count(distinct resource_id) from appointments where call_id like 'corte-%' and estado = 'confirmada'")
[[ "$DIST" == 2 ]] && echo "ok  corte: las 2 citas son de profesionales distintas" || { echo "FALLA corte: $DIST profesionales"; FAIL=1; }

# C) Última red: inserciones directas en la tabla SIN pasar por las funciones (sin bloqueo)
RES=$($P -c "select r.id from resources r where r.nombre = 'Marta'")
SRV=$($P -c "select id from services where codigo = 'corte_hombre' and tenant_id = '11111111-1111-1111-1111-111111111111'")
for i in $(seq 1 "$N"); do
  $P -c "insert into appointments (tenant_id, referencia, nombre_cliente, service_id, resource_id, inicio, fin, fin_bloqueo)
         values ('11111111-1111-1111-1111-111111111111', lpad('$i', 6, '7'), 'Directo $i', '$SRV', '$RES',
                 ('$FECHA 12:00'::timestamp + interval '$((i % 25)) min') at time zone 'Europe/Madrid',
                 ('$FECHA 12:30'::timestamp + interval '$((i % 25)) min') at time zone 'Europe/Madrid',
                 ('$FECHA 12:30'::timestamp + interval '$((i % 25)) min') at time zone 'Europe/Madrid')" > "$TMP/raw.$i" 2>&1 &
done
wait
INS=$($P -c "select count(*) from appointments where nombre_cliente like 'Directo %'")
[[ "$INS" == 1 ]] && echo "ok  inserciones directas solapadas: $N intentos → 1 guardada (citas_sin_solape)" \
                  || { echo "FALLA inserciones directas: $INS guardadas"; FAIL=1; }

# D) Sin solapes en toda la tabla, pase lo que pase
SOL=$($P -c "select count(*) from appointments a join appointments b on a.resource_id = b.resource_id and a.id < b.id
             and a.estado = 'confirmada' and b.estado = 'confirmada'
             and tstzrange(a.inicio, a.fin_bloqueo) && tstzrange(b.inicio, b.fin_bloqueo)")
[[ "$SOL" == 0 ]] && echo "ok  auditoría final: 0 citas solapadas en toda la base de datos" || { echo "FALLA: $SOL solapes"; FAIL=1; }

rm -rf "$TMP"
[[ $FAIL == 0 ]] && echo "══ CONCURRENCIA OK" || { echo "══ CONCURRENCIA CON FALLOS"; exit 1; }
