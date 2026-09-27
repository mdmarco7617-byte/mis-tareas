#!/usr/bin/env bash
# Ejecuta migraciones + seeds + tests en un Postgres local desechable.
# Uso: PGHOST=/var/tmp/pgtest PGPORT=5433 ./supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-verantia_test}
P="psql -U ${PGUSER:-postgres} -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB"
for f in tests/00_bootstrap_local.sql $(ls migrations/*.sql | grep -v purga_automatica) seed/*.sql; do $P -d "$DB" -f "$f"; done
$P -d "$DB" -f tests/01_reservas.sql
DB=$DB tests/02_concurrencia.sh
