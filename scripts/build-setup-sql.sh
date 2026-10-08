#!/usr/bin/env bash
# Concatenates the migrations and the sample data into one file for the Supabase SQL Editor.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- RestRoute demo: full database setup. Paste into Supabase > SQL Editor and Run (once)."
  for f in supabase/migrations/*.sql supabase/seed.sql; do echo; echo "-- ===== $f"; cat "$f"; done
} > supabase/setup_all.sql
wc -c supabase/setup_all.sql
