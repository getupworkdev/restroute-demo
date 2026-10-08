#!/usr/bin/env bash
# Runs the migrations and behaviour tests on a local Postgres with PostGIS.
# Usage: supabase/tests/run.sh   (needs psql access as a superuser; PSQL env var overrides the command)
set -euo pipefail
cd "$(dirname "$0")/../.."
PSQL=${PSQL:-psql}
DB=restroute_test
$PSQL -q -d postgres -c "set client_min_messages=warning" -c "drop database if exists $DB" -c "create database $DB"
$PSQL -q -d $DB -v ON_ERROR_STOP=1 -f supabase/tests/local_stub.sql 2>/dev/null
for f in supabase/migrations/*.sql; do
  $PSQL -q -d $DB -v ON_ERROR_STOP=1 -c "set client_min_messages=warning" -f "$f"
done
$PSQL -q -t -A -d $DB -f supabase/tests/rules_test.sql 2>&1 | sed -e 's/^psql:[^ ]* NOTICE:  /  /' -e '/^$/d' | grep -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} '
