#!/usr/bin/env bash
# Concatenates the migrations and the sample data into one file for the Supabase SQL Editor.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "-- RestRoute demo: full database setup. Paste into Supabase > SQL Editor and Run (once)."
  for f in supabase/migrations/*.sql supabase/seed.sql; do echo; echo "-- ===== $f"; cat "$f"; done
} > supabase/setup_all.sql
wc -c supabase/setup_all.sql

# Reset: removes everything added while testing (non-sample stops, guest users and their
# ratings, reports, prices and photos rows), then reloads the sample stops.
{
  echo "-- RestRoute demo: reset to the original sample data. Paste into Supabase > SQL Editor and Run."
  echo "delete from public.locations where name not like 'Sample %';"
  echo "delete from auth.users where coalesce(raw_user_meta_data ->> 'sample', '') <> 'true';"
  cat supabase/seed.sql
} > supabase/reset_demo.sql
wc -c supabase/reset_demo.sql
