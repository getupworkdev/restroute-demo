-- RestRoute demo: full database setup. Paste into Supabase > SQL Editor and Run (once).

-- ===== supabase/migrations/20261008000000_init.sql
-- RestRoute demo schema (spec v1.2, sections 2-8).
-- Postgres + PostGIS on Supabase. All content is shared: every pin, rating, report,
-- price and photo lives here, and Row Level Security decides who may write what.

create extension if not exists postgis with schema public;

-- ---------------------------------------------------------------- types

create type stop_type as enum (
  'rest_area', 'gas_station', 'truck_stop', 'fast_food', 'store', 'park', 'public_restroom'
);
create type access_type as enum ('free', 'customers', 'code');          -- F3.3
create type tri as enum ('yes', 'no', 'unknown');                         -- F5/F6 editorial rule
create type issue_type as enum ('closed', 'out_of_order', 'no_supplies', 'other'); -- F4.3
create type fuel_grade as enum ('regular', 'midgrade', 'premium', 'diesel');      -- F5.6

-- ---------------------------------------------------------------- users

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Traveler',
  plan text not null default 'free' check (plan in ('free', 'premium')),  -- section 10: read later, no billing in v1
  is_admin boolean not null default false,
  rig_type text,                                                            -- P10.8 rig profile, stored from v1
  rig_length_ft numeric(5, 1),
  rig_height_ft numeric(4, 1),
  created_at timestamptz not null default now()
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', 'Traveler'))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false)
$$;

-- Users edit their own name and rig profile; plan and admin are not theirs to change
-- (only an admin, or the owner from the SQL editor, can).
create function public.guard_profile() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.plan := old.plan;
    new.is_admin := old.is_admin;
  end if;
  return new;
end $$;

create trigger guard_profile before update on public.profiles
  for each row execute function public.guard_profile();

-- ---------------------------------------------------------------- locations

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  stop_type stop_type not null,
  geog geography(Point, 4326) not null,
  lat double precision generated always as (st_y(geog::geometry)) stored,
  lng double precision generated always as (st_x(geog::geometry)) stored,
  highway text,                       -- "I-75", searchable (F2.3)
  city text,
  state text,
  access access_type not null,        -- required (F3.3)
  open_24h boolean not null default false,
  hours jsonb,                        -- {"mon":[["06:00","22:00"]], ...}; feeds "open now" (F3.4)
  tz text not null default 'America/New_York',

  -- F5.1 fuel, F5.2 food, F5.3 parking, F5.4 overnight, F5.5 showers/laundry
  gas tri not null default 'unknown',
  diesel tri not null default 'unknown',
  fast_food tri not null default 'unknown',
  diner tri not null default 'unknown',
  convenience_store tri not null default 'unknown',
  vending tri not null default 'unknown',
  coffee tri not null default 'unknown',
  car_parking tri not null default 'unknown',
  truck_parking tri not null default 'unknown',
  rv_parking tri not null default 'unknown',
  overnight_parking tri not null default 'unknown',
  showers tri not null default 'unknown',
  laundry tri not null default 'unknown',
  -- F5.7 RV services
  rv_dump tri not null default 'unknown',
  dump_fee text check (dump_fee in ('free', 'paid')),
  dump_fee_amount numeric(6, 2),
  rinse_hose tri not null default 'unknown',
  potable_water tri not null default 'unknown',
  potable_note text,
  rv_note text,
  -- F6.1 accessibility & family, F6.2 conveniences
  wheelchair tri not null default 'unknown',
  baby_changing tri not null default 'unknown',
  family_restroom tri not null default 'unknown',
  pet_area tri not null default 'unknown',
  bottle_refill tri not null default 'unknown',
  wifi tri not null default 'unknown',
  ev_charging tri not null default 'unknown',
  picnic tri not null default 'unknown',
  atm tri not null default 'unknown',

  -- maintained by the database, never by clients
  avg_clean numeric(3, 2),
  avg_safety numeric(3, 2),
  avg_supplies numeric(3, 2),
  avg_overall numeric(3, 2),
  rating_count int not null default 0,
  open_issues issue_type[] not null default '{}',   -- open reports; 'closed' hides from default results
  fuel jsonb not null default '{}',                 -- latest price per grade: {"diesel":{"price":3.89,"at":"..."}}
  photo_count int not null default 0,
  last_verified_at timestamptz not null default now(),
  moderation text not null default 'visible' check (moderation in ('visible', 'hidden', 'removed')),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index locations_geog_idx on public.locations using gist (geog);
create index locations_highway_idx on public.locations (upper(highway));

-- Server-owned fields are reset on insert, whatever the client sent.
create function public.locations_before_insert() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then
    new.created_by := auth.uid();
  end if;
  -- Requests from the app carry a user id; seed scripts and the SQL editor do not.
  if auth.uid() is not null and not public.is_admin() then
    new.avg_clean := null; new.avg_safety := null; new.avg_supplies := null; new.avg_overall := null;
    new.rating_count := 0; new.open_issues := '{}'; new.fuel := '{}'; new.photo_count := 0;
    new.last_verified_at := now(); new.moderation := 'visible';
  end if;
  new.highway := nullif(upper(trim(new.highway)), '');
  return new;
end $$;

create trigger locations_before_insert before insert on public.locations
  for each row execute function public.locations_before_insert();

-- Users may update F5/F6 values on any location (editorial rule), but only those columns.
create function public.set_amenities(p_location uuid, p_values jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  allowed text[] := array[
    'gas','diesel','fast_food','diner','convenience_store','vending','coffee',
    'car_parking','truck_parking','rv_parking','overnight_parking','showers','laundry',
    'rv_dump','rinse_hose','potable_water',
    'wheelchair','baby_changing','family_restroom','pet_area','bottle_refill','wifi','ev_charging','picnic','atm'];
  k text;
  v text;
begin
  if auth.uid() is null then
    raise exception 'sign in to edit' using errcode = '42501';
  end if;
  for k, v in select * from jsonb_each_text(p_values) loop
    if k = any (allowed) then
      execute format('update locations set %I = $1::tri, updated_at = now() where id = $2', k) using v, p_location;
    elsif k = 'dump_fee' then
      update locations set dump_fee = nullif(v, ''), updated_at = now() where id = p_location;
    elsif k = 'dump_fee_amount' then
      update locations set dump_fee_amount = nullif(v, '')::numeric, updated_at = now() where id = p_location;
    elsif k in ('potable_note', 'rv_note') then
      execute format('update locations set %I = $1, updated_at = now() where id = $2', k)
        using left(nullif(v, ''), 300), p_location;
    else
      raise exception 'field % cannot be edited', k using errcode = '22023';
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- ratings (F4.1, F4.2)

create table public.ratings (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  clean smallint not null check (clean between 1 and 5),
  safety smallint not null check (safety between 1 and 5),
  supplies smallint not null check (supplies between 1 and 5),
  overall smallint not null check (overall between 1 and 5),
  review text check (char_length(review) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  hidden boolean not null default false,
  unique (location_id, user_id)                      -- one rating set per user per location
);
create index ratings_location_idx on public.ratings (location_id, created_at desc);

create function public.refresh_rating_stats(p_location uuid) returns void
language sql security definer set search_path = public as $$
  update locations l set
    avg_clean = s.c, avg_safety = s.s, avg_supplies = s.p, avg_overall = s.o, rating_count = s.n
  from (
    select round(avg(clean), 2) c, round(avg(safety), 2) s, round(avg(supplies), 2) p,
           round(avg(overall), 2) o, count(*)::int n
    from ratings where location_id = p_location and not hidden
  ) s
  where l.id = p_location
$$;

create function public.ratings_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    return new;
  end if;
  return new;
end $$;

create trigger ratings_touch before update on public.ratings
  for each row execute function public.ratings_changed();

create function public.ratings_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform refresh_rating_stats(coalesce(new.location_id, old.location_id));
  return null;
end $$;

create trigger ratings_after after insert or update or delete on public.ratings
  for each row execute function public.ratings_after();

-- ---------------------------------------------------------------- issue reports (F4.3) & verification (F4.4)

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  issue issue_type not null,
  note text check (char_length(note) <= 500),
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index reports_location_idx on public.reports (location_id) where status = 'open';

create function public.refresh_open_issues(p_location uuid) returns void
language sql security definer set search_path = public as $$
  update locations set open_issues = coalesce(
    (select array_agg(distinct issue order by issue) from reports
      where location_id = p_location and status = 'open'), '{}')
  where id = p_location
$$;

create function public.reports_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform refresh_open_issues(coalesce(new.location_id, old.location_id));
  return null;
end $$;

create trigger reports_after after insert or update or delete on public.reports
  for each row execute function public.reports_after();

create table public.verifications (
  id bigint generated always as identity primary key,
  location_id uuid not null references public.locations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- "I was here - still good": refreshes the stamp and resolves open reports, which brings
-- a location reported closed back into default results.
create function public.verify_location(p_location uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  stamp timestamptz := now();
begin
  if auth.uid() is null then
    raise exception 'sign in to verify' using errcode = '42501';
  end if;
  insert into verifications (location_id, user_id) values (p_location, auth.uid());
  update reports set status = 'resolved', resolved_at = stamp
    where location_id = p_location and status = 'open';
  update locations set last_verified_at = stamp where id = p_location;
  perform refresh_open_issues(p_location);
  return stamp;
end $$;

-- ---------------------------------------------------------------- fuel prices (F5.6)

create table public.fuel_prices (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations (id) on delete cascade,
  grade fuel_grade not null,
  price numeric(5, 3) not null check (price > 0 and price < 20),
  reported_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reported_at timestamptz not null default now()
);
create index fuel_prices_location_idx on public.fuel_prices (location_id, grade, reported_at desc);

create function public.fuel_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update locations set fuel = fuel || jsonb_build_object(
    new.grade::text, jsonb_build_object('price', new.price, 'at', new.reported_at))
  where id = new.location_id;
  return null;
end $$;

create trigger fuel_after after insert on public.fuel_prices
  for each row execute function public.fuel_after();

-- ---------------------------------------------------------------- photos (F3.5)

create table public.photos (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  path text not null,                 -- object path in the "photos" storage bucket
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);

create function public.photos_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  loc uuid := coalesce(new.location_id, old.location_id);
begin
  update locations set photo_count =
    (select count(*) from photos where location_id = loc and not hidden) where id = loc;
  return null;
end $$;

create trigger photos_after after insert or update or delete on public.photos
  for each row execute function public.photos_after();

-- ---------------------------------------------------------------- favorites (F7.2)

create table public.favorites (
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  location_id uuid not null references public.locations (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, location_id)
);

-- ---------------------------------------------------------------- flags & moderation (F7.3, F7.4)

create table public.flags (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('location', 'rating', 'photo')),
  target_id uuid not null,
  location_id uuid references public.locations (id) on delete cascade,
  reported_by uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  reason text not null check (char_length(reason) between 2 and 300),
  status text not null default 'pending' check (status in ('pending', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  unique (target_type, target_id, reported_by)
);

-- Three different users flagging a location hides it from results pending review.
create function public.flags_after() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.target_type = 'location' then
    if (select count(distinct reported_by) from flags
         where target_type = 'location' and target_id = new.target_id and status = 'pending') >= 3 then
      update locations set moderation = 'hidden' where id = new.target_id and moderation = 'visible';
    end if;
  end if;
  return null;
end $$;

create trigger flags_after after insert on public.flags
  for each row execute function public.flags_after();

-- Admin decision on a flag: 'dismiss' leaves the content as it is, 'remove' takes it down,
-- 'restore' puts a hidden location back.
create function public.moderate_flag(p_flag uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare
  f flags;
begin
  if not is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
  select * into f from flags where id = p_flag;
  if not found then
    raise exception 'flag not found';
  end if;
  if p_action = 'remove' then
    if f.target_type = 'location' then
      update locations set moderation = 'removed' where id = f.target_id;
    elsif f.target_type = 'rating' then
      update ratings set hidden = true where id = f.target_id;
    else
      update photos set hidden = true where id = f.target_id;
    end if;
  elsif p_action = 'restore' then
    if f.target_type = 'location' then
      update locations set moderation = 'visible' where id = f.target_id;
    elsif f.target_type = 'rating' then
      update ratings set hidden = false where id = f.target_id;
    else
      update photos set hidden = false where id = f.target_id;
    end if;
  elsif p_action <> 'dismiss' then
    raise exception 'unknown action %', p_action;
  end if;
  update flags set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end
    where target_type = f.target_type and target_id = f.target_id and status = 'pending';
end $$;

-- ---------------------------------------------------------------- queries

-- F2.5: stops within a corridor of the driving route, ordered by distance along the route.
-- route is a GeoJSON LineString (lng/lat). Returns ids plus distances in metres.
create function public.stops_along_route(route jsonb, corridor_m double precision default 1600)
returns table (id uuid, along_m double precision, off_route_m double precision)
language sql stable set search_path = public as $$
  with r as (
    select st_setsrid(st_geomfromgeojson(route::text), 4326) as g
  )
  select l.id,
         st_length(st_linesubstring(r.g, 0, st_linelocatepoint(r.g, l.geog::geometry))::geography) as along_m,
         st_distance(l.geog, r.g::geography) as off_route_m
  from locations l, r
  where l.moderation = 'visible'
    and st_dwithin(l.geog, r.g::geography, corridor_m)
  order by along_m
  limit 500
$$;

-- F2.1 / F2.2: stops near a point, nearest first. Clients filter and sort further.
create function public.stops_near(p_lat double precision, p_lng double precision, radius_m double precision default 80000)
returns table (id uuid, distance_m double precision)
language sql stable set search_path = public as $$
  select l.id, st_distance(l.geog, st_makepoint(p_lng, p_lat)::geography) as distance_m
  from locations l
  where l.moderation = 'visible'
    and st_dwithin(l.geog, st_makepoint(p_lng, p_lat)::geography, radius_m)
  order by distance_m
  limit 500
$$;

-- ---------------------------------------------------------------- row level security

alter table public.profiles enable row level security;
alter table public.locations enable row level security;
alter table public.ratings enable row level security;
alter table public.reports enable row level security;
alter table public.verifications enable row level security;
alter table public.fuel_prices enable row level security;
alter table public.photos enable row level security;
alter table public.favorites enable row level security;
alter table public.flags enable row level security;

-- F7.1: browse freely (anon can read), sign in to contribute.
create policy "profiles readable" on public.profiles for select using (true);
create policy "own profile" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "locations readable" on public.locations for select
  using (moderation = 'visible' or public.is_admin());
create policy "signed-in users add locations" on public.locations for insert to authenticated
  with check (true);
create policy "admins edit locations" on public.locations for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy "ratings readable" on public.ratings for select
  using (not hidden or user_id = auth.uid() or public.is_admin());
create policy "rate as yourself" on public.ratings for insert to authenticated
  with check (user_id = auth.uid());
create policy "edit own rating" on public.ratings for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and not hidden);
create policy "delete own rating" on public.ratings for delete to authenticated
  using (user_id = auth.uid());

create policy "reports readable" on public.reports for select using (true);
create policy "report as yourself" on public.reports for insert to authenticated
  with check (user_id = auth.uid() and status = 'open');

create policy "verifications readable" on public.verifications for select using (true);

create policy "prices readable" on public.fuel_prices for select using (true);
create policy "price as yourself" on public.fuel_prices for insert to authenticated
  with check (reported_by = auth.uid());

create policy "photos readable" on public.photos for select
  using (not hidden or public.is_admin());
create policy "photo as yourself" on public.photos for insert to authenticated
  with check (user_id = auth.uid());

create policy "own favorites" on public.favorites for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "flag as yourself" on public.flags for insert to authenticated
  with check (reported_by = auth.uid() and status = 'pending');
create policy "see own flags, admins see all" on public.flags for select to authenticated
  using (reported_by = auth.uid() or public.is_admin());

-- Functions callable from the app.
revoke execute on function public.refresh_rating_stats(uuid), public.refresh_open_issues(uuid) from public, anon, authenticated;
grant execute on function public.stops_along_route(jsonb, double precision), public.stops_near(double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.verify_location(uuid), public.set_amenities(uuid, jsonb), public.moderate_flag(uuid, text) to authenticated;

-- ---------------------------------------------------------------- realtime: other devices see changes live

alter publication supabase_realtime add table public.locations, public.ratings, public.reports, public.photos, public.fuel_prices;

-- ===== supabase/migrations/20261008000100_storage.sql
-- Photo storage (F3.5): public read, signed-in users upload into a folder named after their user id.
insert into storage.buckets (id, name, public)
values ('photos', 'photos', true)
on conflict (id) do nothing;

create policy "photos are public" on storage.objects for select
  using (bucket_id = 'photos');

create policy "upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ===== supabase/seed.sql
-- Sample data for the RestRoute demo (generated by scripts/make-seed.mjs).
-- Stops sit on real highway geometry; names, ratings and prices are invented samples.
-- Safe to re-run: removes the previous sample data first.
begin;
delete from auth.users where raw_user_meta_data ->> 'sample' = 'true';
delete from public.locations where name like 'Sample %';

insert into auth.users (instance_id, id, aud, role, raw_user_meta_data, raw_app_meta_data, is_anonymous, created_at, updated_at) values
  ('00000000-0000-0000-0000-000000000000', 'f703b145-ef45-4c25-a98b-139ca4c55886', 'authenticated', 'authenticated', '{"display_name":"Dana","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 'authenticated', 'authenticated', '{"display_name":"Luis","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 'authenticated', 'authenticated', '{"display_name":"Priya","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', '44271939-51f9-45d8-a7fc-f8da7217ef85', 'authenticated', 'authenticated', '{"display_name":"Mike","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 'authenticated', 'authenticated', '{"display_name":"Tasha","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 'authenticated', 'authenticated', '{"display_name":"Ray","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 'authenticated', 'authenticated', '{"display_name":"Jen","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 'authenticated', 'authenticated', '{"display_name":"Omar","sample":"true"}'::jsonb, '{}'::jsonb, true, now(), now());

insert into public.locations (geog, id, name, stop_type, highway, city, state, access, open_24h, hours, tz, gas, diesel, fast_food, diner, convenience_store, vending, coffee, car_parking, truck_parking, rv_parking, overnight_parking, showers, laundry, rv_dump, dump_fee, dump_fee_amount, rinse_hose, potable_water, potable_note, rv_note, wheelchair, baby_changing, family_restroom, pet_area, bottle_refill, wifi, ev_charging, picnic, atm, created_by, created_at, last_verified_at) values
  ('SRID=4326;POINT(-84.431743 33.857926)', 'f2c389ec-8602-40ff-abd3-3aa288e30187', 'Sample Store 1 · I-75', 'store', 'I-75', null, 'GA / TN', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'unknown', 'no', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'no', 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'no', 'no', 'yes', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-04-07T12:00:00.000Z', '2026-08-28T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.540332 33.986095)', 'cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'Sample Gas Station 1 · I-75', 'gas_station', 'I-75', null, 'GA / TN', 'customers', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/New_York', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'no', 'yes', 'yes', 'no', 'unknown', 'no', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'no', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'yes', 'unknown', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-02-16T12:00:00.000Z', '2026-09-21T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.691807 34.085684)', '3c4b490b-1194-44a2-a2ef-3de040336bcc', 'Sample Truck Stop 1 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'yes', 'no', 'yes', 'no', 'yes', 'yes', 'yes', 'yes', 'yes', 'no', 'yes', 'unknown', null, null, 'unknown', 'yes', 'Hose bib on the north side of the building', null, 'yes', 'unknown', 'no', 'unknown', 'no', 'unknown', 'unknown', 'no', 'yes', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-01-28T12:00:00.000Z', '2026-09-13T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.76638 34.244455)', '36e8740f-1870-4077-a68a-dc3b99c3fb63', 'Sample Gas Station 2 · I-75', 'gas_station', 'I-75', null, 'GA / TN', 'free', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/New_York', 'yes', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'no', 'unknown', 'yes', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'no', 'no', 'yes', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-04-12T12:00:00.000Z', '2026-09-21T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.916566 34.409714)', '2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'Sample Truck Stop 2 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'no', 'no', 'yes', 'unknown', 'no', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'unknown', null, null, 'unknown', 'yes', 'Threaded spigot by the dump station', null, 'no', 'yes', 'yes', 'unknown', 'no', 'yes', 'yes', 'yes', 'yes', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2025-12-08T12:00:00.000Z', '2026-09-24T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.926653 34.550052)', 'f3e6f617-f5a0-40a2-a237-87fc33af539a', 'Sample Truck Stop 3 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'no', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'free', null, 'yes', 'no', null, 'Tight turn on entry, under 35 ft recommended', 'yes', 'yes', 'no', 'unknown', 'yes', 'unknown', 'no', 'no', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2025-09-23T12:00:00.000Z', '2026-09-27T12:00:00.000Z'),
  ('SRID=4326;POINT(-85.00166 34.69674)', 'f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'Sample Truck Stop 4 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'no', null, null, 'unknown', 'no', null, null, 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'no', 'no', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-02-13T12:00:00.000Z', '2026-09-10T12:00:00.000Z'),
  ('SRID=4326;POINT(-85.033428 34.86772)', '32eb6feb-43a3-4d66-a121-f3c1d7ae4031', 'Sample Fast Food 1 · I-75', 'fast_food', 'I-75', null, 'GA / TN', 'customers', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'no', 'yes', 'yes', 'unknown', 'unknown', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-05-25T12:00:00.000Z', '2026-09-01T12:00:00.000Z'),
  ('SRID=4326;POINT(-85.256585 35.015693)', 'e73eab24-9608-4d36-aa89-6abb008d9a39', 'Sample Fast Food 2 · I-75', 'fast_food', 'I-75', null, 'GA / TN', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'yes', 'unknown', 'no', 'yes', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'no', 'unknown', 'unknown', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2025-10-07T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('SRID=4326;POINT(-85.281858 35.014509)', '022b6396-428b-494e-ac36-a5fa8f47de4c', 'Sample Truck Stop 5 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'no', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'no', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'no', 'yes', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-04-15T12:00:00.000Z', '2026-09-16T12:00:00.000Z'),
  ('SRID=4326;POINT(-85.145333 35.049174)', '37992196-64a0-48a7-a2e4-9b749d405273', 'Sample Truck Stop 6 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'customers', true, null, 'America/New_York', 'yes', 'yes', 'no', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'no', 'no', null, null, 'unknown', 'yes', 'Hose bib on the north side of the building', null, 'yes', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'no', 'no', 'yes', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-02-02T12:00:00.000Z', '2026-07-02T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.935556 35.162383)', 'aa8ccc30-a214-44f0-af6c-c067b349d650', 'Sample Truck Stop 7 · I-75', 'truck_stop', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'yes', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'no', null, null, 'unknown', 'yes', 'Hose bib on the north side of the building', null, 'yes', 'yes', 'yes', 'yes', 'unknown', 'unknown', 'no', 'no', 'yes', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2025-12-07T12:00:00.000Z', '2026-09-15T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.797751 35.313952)', 'f00daec8-e853-4a78-a382-2940ac50f911', 'Sample Rest Area 1 · I-75', 'rest_area', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'no', 'no', 'yes', 'no', 'unknown', 'yes', 'unknown', 'yes', 'no', 'yes', 'no', 'unknown', 'unknown', 'no', null, null, 'unknown', 'yes', 'Hose bib on the north side of the building', null, 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'unknown', 'yes', 'no', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2025-11-03T12:00:00.000Z', '2026-10-03T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.641035 35.476831)', '16d581a6-ff64-450e-ac7f-3ac44526f7d1', 'Sample Public Restroom 1 · I-75', 'public_restroom', 'I-75', null, 'GA / TN', 'free', false, '{"mon":[["06:00","20:00"]],"tue":[["06:00","20:00"]],"wed":[["06:00","20:00"]],"thu":[["06:00","20:00"]],"fri":[["06:00","20:00"]],"sat":[["06:00","20:00"]],"sun":[["08:00","18:00"]]}'::jsonb, 'America/New_York', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'no', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'yes', 'unknown', 'unknown', 'no', 'yes', 'unknown', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-03-17T12:00:00.000Z', '2026-09-14T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.481996 35.6318)', '0666a080-857d-45ea-a272-58a91589a143', 'Sample Fast Food 3 · I-75', 'fast_food', 'I-75', null, 'GA / TN', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'yes', 'no', 'unknown', 'yes', 'yes', 'yes', 'no', 'unknown', 'no', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'unknown', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2025-10-01T12:00:00.000Z', '2026-10-02T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.378163 35.749071)', '537d1367-14f0-4a18-ab1b-ee5015617612', 'Sample Rest Area 2 · I-75', 'rest_area', 'I-75', null, 'GA / TN', 'free', true, null, 'America/New_York', 'no', 'no', 'unknown', 'no', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'no', 'unknown', 'no', 'yes', 'no', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-04-24T12:00:00.000Z', '2026-09-21T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.210354 35.890879)', '386e3186-90a0-4314-a22a-4ff01b316db1', 'Sample Park 1 · I-75', 'park', 'I-75', null, 'GA / TN', 'free', false, '{"mon":[["07:00","19:30"]],"tue":[["07:00","19:30"]],"wed":[["07:00","19:30"]],"thu":[["07:00","19:30"]],"fri":[["07:00","19:30"]],"sat":[["07:00","19:30"]],"sun":[["07:00","19:30"]]}'::jsonb, 'America/New_York', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'no', 'no', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'yes', 'no', 'yes', 'unknown', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-03-19T12:00:00.000Z', '2026-06-23T12:00:00.000Z'),
  ('SRID=4326;POINT(-84.065338 35.925526)', '7bf04df7-bb52-4cc4-a07f-834249d0700f', 'Sample Gas Station 3 · I-75', 'gas_station', 'I-75', null, 'GA / TN', 'free', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/New_York', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'yes', 'no', 'unknown', 'no', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'yes', 'no', 'unknown', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-02-21T12:00:00.000Z', '2026-09-29T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.671037 30.371349)', '15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', 'Sample Store 1 · I-95', 'store', 'I-95', null, 'FL / GA', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'no', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'no', 'unknown', 'no', 'unknown', 'no', 'no', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-01-06T12:00:00.000Z', '2026-08-27T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.639867 30.543423)', 'ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'Sample Gas Station 1 · I-95', 'gas_station', 'I-95', null, 'FL / GA', 'free', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/New_York', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'yes', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-05-02T12:00:00.000Z', '2026-08-26T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.674164 30.683876)', 'e652fe83-f588-4e4d-a3e1-e16741f40e85', 'Sample Rest Area 1 · I-95', 'rest_area', 'I-95', null, 'FL / GA', 'free', true, null, 'America/New_York', 'no', 'no', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'no', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'unknown', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2025-10-26T12:00:00.000Z', '2026-01-27T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.683483 30.868355)', '9e73f084-488f-40ba-a30e-0e6d8f931cbf', 'Sample Fast Food 1 · I-95', 'fast_food', 'I-95', null, 'FL / GA', 'customers', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'unknown', 'no', 'no', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'unknown', 'no', 'unknown', 'no', 'unknown', 'no', 'unknown', 'unknown', 'unknown', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-05-27T12:00:00.000Z', '2026-10-06T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.655487 31.034518)', 'f5ce41a7-6277-4bc4-a631-758d414c8773', 'Sample Store 2 · I-95', 'store', 'I-95', null, 'FL / GA', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'no', 'unknown', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'unknown', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2025-09-28T12:00:00.000Z', '2026-02-02T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.536864 31.197031)', '743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'Sample Truck Stop 1 · I-95', 'truck_stop', 'I-95', null, 'FL / GA', 'customers', true, null, 'America/New_York', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'no', 'yes', 'paid', 5, 'unknown', 'unknown', null, 'Pull-through lane, fits 40 ft rigs', 'yes', 'unknown', 'yes', 'no', 'yes', 'yes', 'no', 'no', 'yes', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2025-11-04T12:00:00.000Z', '2026-04-05T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.484039 31.300614)', 'c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'Sample Gas Station 2 · I-95', 'gas_station', 'I-95', null, 'FL / GA', 'free', true, null, 'America/New_York', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'no', 'no', 'unknown', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'yes', 'no', 'no', 'yes', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-05-10T12:00:00.000Z', '2026-09-15T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.448158 31.469719)', '2ece299d-88b7-498b-a6c4-1c3fb96299a0', 'Sample Public Restroom 1 · I-95', 'public_restroom', 'I-95', null, 'FL / GA', 'free', false, '{"mon":[["06:00","20:00"]],"tue":[["06:00","20:00"]],"wed":[["06:00","20:00"]],"thu":[["06:00","20:00"]],"fri":[["06:00","20:00"]],"sat":[["06:00","20:00"]],"sun":[["08:00","18:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'no', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'no', 'no', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-01-22T12:00:00.000Z', '2026-09-23T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.410498 31.6173)', 'b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'Sample Truck Stop 2 · I-95', 'truck_stop', 'I-95', null, 'FL / GA', 'free', true, null, 'America/New_York', 'yes', 'yes', 'no', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'yes', 'free', null, 'yes', 'yes', 'Threaded spigot by the dump station', 'Pull-through lane, fits 40 ft rigs', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'yes', 'no', 'unknown', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-04-01T12:00:00.000Z', '2026-09-05T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.334481 31.862122)', '18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc', 'Sample Fast Food 2 · I-95', 'fast_food', 'I-95', null, 'FL / GA', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/New_York', 'unknown', 'no', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'no', 'yes', 'unknown', 'unknown', 'unknown', 'no', 'no', 'no', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2025-10-05T12:00:00.000Z', '2026-09-30T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.329086 31.962871)', 'dfab0b80-6065-43b8-aafa-937c57807f27', 'Sample Gas Station 3 · I-95', 'gas_station', 'I-95', null, 'FL / GA', 'free', true, null, 'America/New_York', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'no', 'no', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2025-10-14T12:00:00.000Z', '2026-02-24T12:00:00.000Z'),
  ('SRID=4326;POINT(-81.24222 32.071966)', '5df80887-7463-4c0a-adcb-e6524750d48c', 'Sample Store 3 · I-95', 'store', 'I-95', null, 'FL / GA', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/New_York', 'no', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'unknown', 'no', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'no', 'no', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-05-31T12:00:00.000Z', '2026-09-05T12:00:00.000Z'),
  ('SRID=4326;POINT(-95.438176 29.776893)', '07b5a3ab-0aec-40c4-ac14-aad41e9052d7', 'Sample Rest Area 1 · I-10', 'rest_area', 'I-10', null, 'TX', 'free', true, null, 'America/Chicago', 'no', 'no', 'yes', 'unknown', 'unknown', 'yes', 'no', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'no', null, null, 'unknown', 'no', null, null, 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'no', 'yes', 'unknown', '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-04-26T12:00:00.000Z', '2026-09-25T12:00:00.000Z'),
  ('SRID=4326;POINT(-95.648519 29.786709)', 'c418721a-85a3-4003-a5ee-9f8e80ed4a65', 'Sample Public Restroom 1 · I-10', 'public_restroom', 'I-10', null, 'TX', 'free', false, '{"mon":[["06:00","20:00"]],"tue":[["06:00","20:00"]],"wed":[["06:00","20:00"]],"thu":[["06:00","20:00"]],"fri":[["06:00","20:00"]],"sat":[["06:00","20:00"]],"sun":[["08:00","18:00"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'unknown', 'yes', 'no', 'yes', 'no', 'yes', 'no', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2025-10-02T12:00:00.000Z', '2026-09-20T12:00:00.000Z'),
  ('SRID=4326;POINT(-95.972161 29.777977)', 'a7ad1946-101a-4969-a9e1-d739b85a1e9c', 'Sample Store 1 · I-10', 'store', 'I-10', null, 'TX', 'code', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'yes', 'no', 'no', 'no', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'unknown', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-01-17T12:00:00.000Z', '2026-01-22T12:00:00.000Z'),
  ('SRID=4326;POINT(-96.183256 29.761318)', '2f377044-7f84-4d16-a631-909380d0066b', 'Sample Rest Area 2 · I-10', 'rest_area', 'I-10', null, 'TX', 'free', true, null, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'no', 'unknown', 'yes', 'paid', 5, 'yes', 'yes', 'Hose bib on the north side of the building', 'Behind the diesel island', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'no', 'yes', 'unknown', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-02-24T12:00:00.000Z', '2026-08-29T12:00:00.000Z'),
  ('SRID=4326;POINT(-96.342254 29.738014)', '0fbc829a-950d-48ec-aaf1-2c25858f4eb8', 'Sample Rest Area 3 · I-10', 'rest_area', 'I-10', null, 'TX', 'free', true, null, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'unknown', 'no', null, null, 'unknown', 'no', null, null, 'yes', 'yes', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'no', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2025-12-19T12:00:00.000Z', '2026-08-25T12:00:00.000Z'),
  ('SRID=4326;POINT(-96.653815 29.692388)', 'b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'Sample Gas Station 1 · I-10', 'gas_station', 'I-10', null, 'TX', 'customers', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/Chicago', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'yes', 'no', 'unknown', 'unknown', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'no', 'unknown', 'no', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-05-04T12:00:00.000Z', '2026-03-27T12:00:00.000Z'),
  ('SRID=4326;POINT(-96.835696 29.691242)', 'd2516c62-2ea9-4870-a7ee-2f4a4c5643e0', 'Sample Rest Area 4 · I-10', 'rest_area', 'I-10', null, 'TX', 'free', true, null, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'yes', 'unknown', 'no', 'unknown', 'yes', 'unknown', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2025-10-25T12:00:00.000Z', '2026-09-30T12:00:00.000Z'),
  ('SRID=4326;POINT(-97.083469 29.699466)', '7ab421c5-d390-4d40-ab66-87eaa267f363', 'Sample Fast Food 1 · I-10', 'fast_food', 'I-10', null, 'TX', 'customers', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'yes', 'yes', 'unknown', 'no', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'no', 'no', 'unknown', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-04-13T12:00:00.000Z', '2026-09-18T12:00:00.000Z'),
  ('SRID=4326;POINT(-97.321533 29.666322)', '77cd3209-e943-4b5f-a4c2-03c0efc022e1', 'Sample Gas Station 2 · I-10', 'gas_station', 'I-10', null, 'TX', 'free', true, null, 'America/Chicago', 'yes', 'no', 'no', 'unknown', 'yes', 'yes', 'yes', 'yes', 'unknown', 'no', 'no', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', '44271939-51f9-45d8-a7fc-f8da7217ef85', '2025-10-31T12:00:00.000Z', '2026-09-14T12:00:00.000Z'),
  ('SRID=4326;POINT(-97.543652 29.655128)', 'eccb633a-9c2b-4c61-ad5c-dd786f55ae33', 'Sample Park 1 · I-10', 'park', 'I-10', null, 'TX', 'free', false, '{"mon":[["07:00","19:30"]],"tue":[["07:00","19:30"]],"wed":[["07:00","19:30"]],"thu":[["07:00","19:30"]],"fri":[["07:00","19:30"]],"sat":[["07:00","19:30"]],"sun":[["07:00","19:30"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'unknown', 'unknown', 'no', 'yes', 'yes', 'yes', 'yes', 'no', 'unknown', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'no', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-03-10T12:00:00.000Z', '2026-09-20T12:00:00.000Z'),
  ('SRID=4326;POINT(-97.801619 29.61399)', '464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'Sample Truck Stop 1 · I-10', 'truck_stop', 'I-10', null, 'TX', 'customers', true, null, 'America/Chicago', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'paid', 7.5, 'yes', 'no', null, 'Behind the diesel island', 'yes', 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2025-10-31T12:00:00.000Z', '2026-08-28T12:00:00.000Z'),
  ('SRID=4326;POINT(-97.911076 29.598867)', '69ffd908-9d4f-4d12-a996-c02f2c879c20', 'Sample Store 2 · I-10', 'store', 'I-10', null, 'TX', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'yes', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'yes', 'no', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'no', 'unknown', 'yes', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-05-09T12:00:00.000Z', '2026-02-26T12:00:00.000Z'),
  ('SRID=4326;POINT(-98.14378 29.518649)', '831472bb-d054-4490-a918-f3a87b3aeff5', 'Sample Fast Food 2 · I-10', 'fast_food', 'I-10', null, 'TX', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Chicago', 'no', 'no', 'yes', 'unknown', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'no', 'no', 'yes', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'no', 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-02-01T12:00:00.000Z', '2026-09-18T12:00:00.000Z'),
  ('SRID=4326;POINT(-98.399144 29.431607)', 'a4ae93aa-bc1b-48dd-adef-9dab34e2e90d', 'Sample Public Restroom 2 · I-10', 'public_restroom', 'I-10', null, 'TX', 'free', false, '{"mon":[["06:00","20:00"]],"tue":[["06:00","20:00"]],"wed":[["06:00","20:00"]],"thu":[["06:00","20:00"]],"fri":[["06:00","20:00"]],"sat":[["06:00","20:00"]],"sun":[["08:00","18:00"]]}'::jsonb, 'America/Chicago', 'unknown', 'no', 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'yes', 'no', 'unknown', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'yes', 'no', 'no', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2025-10-29T12:00:00.000Z', '2026-09-29T12:00:00.000Z'),
  ('SRID=4326;POINT(-111.766705 35.202082)', '6a8145ec-fbf8-4515-ae17-845cf6c17fd8', 'Sample Store 1 · I-40', 'store', 'I-40', null, 'AZ', 'customers', false, '{"mon":[["07:00","22:00"]],"tue":[["07:00","22:00"]],"wed":[["07:00","22:00"]],"thu":[["07:00","22:00"]],"fri":[["07:00","22:00"]],"sat":[["07:00","22:00"]],"sun":[["07:00","22:00"]]}'::jsonb, 'America/Phoenix', 'unknown', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'yes', 'no', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'no', 'unknown', 'yes', 'unknown', 'unknown', 'unknown', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-01-23T12:00:00.000Z', '2026-09-21T12:00:00.000Z'),
  ('SRID=4326;POINT(-111.966795 35.247016)', 'fee4a600-35a2-465e-ae23-0c0c97e18bbc', 'Sample Fast Food 1 · I-40', 'fast_food', 'I-40', null, 'AZ', 'customers', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Phoenix', 'no', 'no', 'yes', 'unknown', 'unknown', 'no', 'yes', 'yes', 'no', 'no', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'no', 'unknown', 'unknown', 'no', 'no', 'unknown', 'unknown', 'unknown', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-03-15T12:00:00.000Z', '2026-09-27T12:00:00.000Z'),
  ('SRID=4326;POINT(-112.105214 35.260672)', '5abfe274-8135-4073-a8a1-c6c449aac7ac', 'Sample Gas Station 1 · I-40', 'gas_station', 'I-40', null, 'AZ', 'free', true, null, 'America/Phoenix', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'no', 'yes', 'no', 'yes', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'no', 'yes', '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2025-12-30T12:00:00.000Z', '2026-10-07T12:00:00.000Z'),
  ('SRID=4326;POINT(-112.363012 35.217134)', '4eaafb81-f19b-41c9-af91-a66c22c09ef5', 'Sample Truck Stop 1 · I-40', 'truck_stop', 'I-40', null, 'AZ', 'free', true, null, 'America/Phoenix', 'yes', 'yes', 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'yes', 'no', null, null, 'unknown', 'no', null, null, 'yes', 'no', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'unknown', 'unknown', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-03-07T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('SRID=4326;POINT(-112.508532 35.219287)', '39f955e1-c343-459c-a1e4-6e25aada3514', 'Sample Rest Area 1 · I-40', 'rest_area', 'I-40', null, 'AZ', 'free', true, null, 'America/Phoenix', 'no', 'no', 'unknown', 'no', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'yes', 'no', 'yes', 'unknown', 'unknown', null, null, 'unknown', 'yes', 'Hose bib on the north side of the building', null, 'unknown', 'yes', 'unknown', 'yes', 'unknown', 'yes', 'no', 'yes', 'unknown', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2025-10-08T12:00:00.000Z', '2026-09-14T12:00:00.000Z'),
  ('SRID=4326;POINT(-112.756516 35.275334)', 'a0ccb4d3-d3b5-4908-aaae-e4e1f2684a95', 'Sample Public Restroom 1 · I-40', 'public_restroom', 'I-40', null, 'AZ', 'free', false, '{"mon":[["06:00","20:00"]],"tue":[["06:00","20:00"]],"wed":[["06:00","20:00"]],"thu":[["06:00","20:00"]],"fri":[["06:00","20:00"]],"sat":[["06:00","20:00"]],"sun":[["08:00","18:00"]]}'::jsonb, 'America/Phoenix', 'unknown', 'no', 'no', 'unknown', 'unknown', 'no', 'unknown', 'yes', 'no', 'no', 'no', 'no', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'no', 'no', 'unknown', '44271939-51f9-45d8-a7fc-f8da7217ef85', '2025-12-28T12:00:00.000Z', '2026-09-09T12:00:00.000Z'),
  ('SRID=4326;POINT(-113.032006 35.291831)', '4f35c002-ef64-44f4-a905-64d28697d0fa', 'Sample Fast Food 2 · I-40', 'fast_food', 'I-40', null, 'AZ', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Phoenix', 'unknown', 'no', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'yes', 'no', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'yes', 'unknown', 'yes', 'yes', 'no', 'yes', 'no', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2025-11-27T12:00:00.000Z', '2026-08-26T12:00:00.000Z'),
  ('SRID=4326;POINT(-113.201157 35.238332)', '1b4f54fd-a331-4264-a020-c42f15d574a1', 'Sample Fast Food 3 · I-40', 'fast_food', 'I-40', null, 'AZ', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Phoenix', 'no', 'no', 'yes', 'no', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'no', 'no', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'no', 'no', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2025-10-30T12:00:00.000Z', '2026-09-20T12:00:00.000Z'),
  ('SRID=4326;POINT(-113.397301 35.192068)', 'a6d93f76-0c04-485c-ade7-1d4e28d40b9d', 'Sample Fast Food 4 · I-40', 'fast_food', 'I-40', null, 'AZ', 'code', false, '{"mon":[["06:00","23:00"]],"tue":[["06:00","23:00"]],"wed":[["06:00","23:00"]],"thu":[["06:00","23:00"]],"fri":[["06:00","23:00"]],"sat":[["06:00","23:00"]],"sun":[["06:00","23:00"]]}'::jsonb, 'America/Phoenix', 'no', 'no', 'yes', 'unknown', 'no', 'unknown', 'yes', 'yes', 'unknown', 'yes', 'unknown', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'yes', 'yes', 'unknown', 'yes', 'yes', 'no', 'no', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-03-25T12:00:00.000Z', '2026-09-28T12:00:00.000Z'),
  ('SRID=4326;POINT(-113.512499 35.169163)', 'a3785304-3931-4990-a970-8ece22f22f14', 'Sample Gas Station 2 · I-40', 'gas_station', 'I-40', null, 'AZ', 'free', false, '{"mon":[["05:00","23:00"]],"tue":[["05:00","23:00"]],"wed":[["05:00","23:00"]],"thu":[["05:00","23:00"]],"fri":[["05:00","23:00"]],"sat":[["05:00","23:00"]],"sun":[["05:00","23:00"]]}'::jsonb, 'America/Phoenix', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'no', 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'no', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'unknown', 'unknown', 'unknown', 'yes', 'no', 'no', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-05-01T12:00:00.000Z', '2026-08-29T12:00:00.000Z'),
  ('SRID=4326;POINT(-113.770763 35.172951)', '4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'Sample Gas Station 3 · I-40', 'gas_station', 'I-40', null, 'AZ', 'free', true, null, 'America/Phoenix', 'yes', 'yes', 'unknown', 'unknown', 'yes', 'unknown', 'yes', 'yes', 'unknown', 'no', 'unknown', 'unknown', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'yes', 'unknown', 'unknown', 'yes', 'yes', 'unknown', 'unknown', 'yes', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-04-27T12:00:00.000Z', '2026-08-31T12:00:00.000Z'),
  ('SRID=4326;POINT(-114.003558 35.218704)', '27fca49b-e619-4b8a-a575-52ecd7a9d5aa', 'Sample Rest Area 2 · I-40', 'rest_area', 'I-40', null, 'AZ', 'free', true, null, 'America/Phoenix', 'no', 'no', 'yes', 'unknown', 'unknown', 'no', 'unknown', 'yes', 'yes', 'no', 'no', 'no', 'unknown', 'unknown', null, null, 'unknown', 'unknown', null, null, 'yes', 'unknown', 'yes', 'yes', 'yes', 'no', 'unknown', 'yes', 'unknown', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2025-11-06T12:00:00.000Z', '2026-08-30T12:00:00.000Z');

insert into public.ratings (location_id, user_id, clean, safety, supplies, overall, review, created_at, updated_at) values
  ('f2c389ec-8602-40ff-abd3-3aa288e30187', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 3, 4, 2, 'Out of soap and paper.', '2026-07-07T12:00:00.000Z', '2026-07-07T12:00:00.000Z'),
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 3, 3, 3, 'Okay, could use more paper towels.', '2026-07-22T12:00:00.000Z', '2026-07-22T12:00:00.000Z'),
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 2, 4, 3, 'Fine for a quick stop.', '2026-06-30T12:00:00.000Z', '2026-06-30T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 4, 2, 3, 'Decent but the hand dryer was broken.', '2026-04-04T12:00:00.000Z', '2026-04-04T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 4, 3, 3, 'Fine for a quick stop.', '2026-08-02T12:00:00.000Z', '2026-08-02T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 4, 3, 4, 'Spotless and well lit at night.', '2026-08-21T12:00:00.000Z', '2026-08-21T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 3, 3, 3, null, '2026-08-15T12:00:00.000Z', '2026-08-15T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 4, 4, 3, null, '2026-09-22T12:00:00.000Z', '2026-09-22T12:00:00.000Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 3, 3, 3, null, '2026-04-15T12:00:00.000Z', '2026-04-15T12:00:00.000Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 5, 4, 4, 5, null, '2026-10-07T12:00:00.000Z', '2026-10-07T12:00:00.000Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 4, 4, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-06-18T12:00:00.000Z', '2026-06-18T12:00:00.000Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 4, 3, 5, null, '2026-06-29T12:00:00.000Z', '2026-06-29T12:00:00.000Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 5, 4, 4, 5, 'Clean, stocked, easy in and out.', '2026-09-10T12:00:00.000Z', '2026-09-10T12:00:00.000Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 5, 4, 4, 5, null, '2026-08-02T12:00:00.000Z', '2026-08-02T12:00:00.000Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 5, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-06T12:00:00.000Z', '2026-05-06T12:00:00.000Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 4, 4, 5, null, '2026-07-10T12:00:00.000Z', '2026-07-10T12:00:00.000Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 5, 5, 5, 5, null, '2026-04-12T12:00:00.000Z', '2026-04-12T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 3, 3, 4, null, '2026-04-23T12:00:00.000Z', '2026-04-23T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 2, 3, 4, 'Family restroom was clean, changing table worked.', '2026-07-27T12:00:00.000Z', '2026-07-27T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 3, 3, 2, 4, null, '2026-09-22T12:00:00.000Z', '2026-09-22T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 4, 4, 3, 'Decent but the hand dryer was broken.', '2026-09-04T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 4, 3, 4, 'Clean, stocked, easy in and out.', '2026-04-09T12:00:00.000Z', '2026-04-09T12:00:00.000Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 3, 2, 2, null, '2026-09-16T12:00:00.000Z', '2026-09-16T12:00:00.000Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 5, 5, 3, 'Decent but the hand dryer was broken.', '2026-08-07T12:00:00.000Z', '2026-08-07T12:00:00.000Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 4, 5, 5, 4, 'Spotless and well lit at night.', '2026-05-27T12:00:00.000Z', '2026-05-27T12:00:00.000Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 5, 4, 4, null, '2026-08-23T12:00:00.000Z', '2026-08-23T12:00:00.000Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 3, 5, 5, null, '2026-08-01T12:00:00.000Z', '2026-08-01T12:00:00.000Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', '44271939-51f9-45d8-a7fc-f8da7217ef85', 5, 4, 5, 5, null, '2026-06-29T12:00:00.000Z', '2026-06-29T12:00:00.000Z'),
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 3, 5, null, '2026-07-30T12:00:00.000Z', '2026-07-30T12:00:00.000Z'),
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 4, 5, 'Safe feeling at 2am, lots of lights.', '2026-09-24T12:00:00.000Z', '2026-09-24T12:00:00.000Z'),
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 5, 5, 3, 5, 'Best stop on this stretch.', '2026-06-09T12:00:00.000Z', '2026-06-09T12:00:00.000Z'),
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 4, 4, 5, 'Spotless and well lit at night.', '2026-09-01T12:00:00.000Z', '2026-09-01T12:00:00.000Z'),
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 4, 4, 4, null, '2026-07-02T12:00:00.000Z', '2026-07-02T12:00:00.000Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 4, 3, null, '2026-07-26T12:00:00.000Z', '2026-07-26T12:00:00.000Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 3, 3, 4, 4, null, '2026-10-01T12:00:00.000Z', '2026-10-01T12:00:00.000Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 4, 3, 3, null, '2026-09-24T12:00:00.000Z', '2026-09-24T12:00:00.000Z'),
  ('aa8ccc30-a214-44f0-af6c-c067b349d650', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 3, 4, 3, null, '2026-09-22T12:00:00.000Z', '2026-09-22T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 4, 2, 3, 3, null, '2026-05-12T12:00:00.000Z', '2026-05-12T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 4, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-27T12:00:00.000Z', '2026-05-27T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 3, 3, 4, 3, 'Decent but the hand dryer was broken.', '2026-09-08T12:00:00.000Z', '2026-09-08T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 4, 3, null, '2026-07-09T12:00:00.000Z', '2026-07-09T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 3, 4, null, '2026-06-13T12:00:00.000Z', '2026-06-13T12:00:00.000Z'),
  ('f00daec8-e853-4a78-a382-2940ac50f911', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 3, 3, 3, null, '2026-09-04T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 2, 2, 1, 'Dark lot, would not stop at night.', '2026-09-24T12:00:00.000Z', '2026-09-24T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', '44271939-51f9-45d8-a7fc-f8da7217ef85', 2, 1, 2, 1, 'Out of soap and paper.', '2026-04-19T12:00:00.000Z', '2026-04-19T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 2, 3, 2, 2, 'Needs cleaning badly.', '2026-09-10T12:00:00.000Z', '2026-09-10T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 2, 3, 3, 2, null, '2026-09-07T12:00:00.000Z', '2026-09-07T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 2, 3, 2, null, '2026-06-03T12:00:00.000Z', '2026-06-03T12:00:00.000Z'),
  ('16d581a6-ff64-450e-ac7f-3ac44526f7d1', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 2, 2, 2, 2, 'Dark lot, would not stop at night.', '2026-07-26T12:00:00.000Z', '2026-07-26T12:00:00.000Z'),
  ('0666a080-857d-45ea-a272-58a91589a143', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 5, 4, 5, 5, 'Staff keeps it tidy. Plenty of parking.', '2026-09-15T12:00:00.000Z', '2026-09-15T12:00:00.000Z'),
  ('537d1367-14f0-4a18-ab1b-ee5015617612', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 3, 4, 3, null, '2026-10-05T12:00:00.000Z', '2026-10-05T12:00:00.000Z'),
  ('386e3186-90a0-4314-a22a-4ff01b316db1', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 4, 4, 5, 'Family restroom was clean, changing table worked.', '2026-05-09T12:00:00.000Z', '2026-05-09T12:00:00.000Z'),
  ('386e3186-90a0-4314-a22a-4ff01b316db1', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 4, 4, 3, 'Okay, could use more paper towels.', '2026-10-05T12:00:00.000Z', '2026-10-05T12:00:00.000Z'),
  ('386e3186-90a0-4314-a22a-4ff01b316db1', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 4, 5, 4, null, '2026-04-04T12:00:00.000Z', '2026-04-04T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 2, 1, 2, 'Dark lot, would not stop at night.', '2026-05-30T12:00:00.000Z', '2026-05-30T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 2, 3, 2, 'Dark lot, would not stop at night.', '2026-09-17T12:00:00.000Z', '2026-09-17T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 2, 3, 3, 'Fine for a quick stop.', '2026-09-26T12:00:00.000Z', '2026-09-26T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 3, 3, 2, null, '2026-08-27T12:00:00.000Z', '2026-08-27T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 2, 2, 2, 2, 'Dark lot, would not stop at night.', '2026-06-30T12:00:00.000Z', '2026-06-30T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 3, 3, 4, 'Safe feeling at 2am, lots of lights.', '2026-06-30T12:00:00.000Z', '2026-06-30T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 3, 4, 3, 3, 'Okay, could use more paper towels.', '2026-10-07T12:00:00.000Z', '2026-10-07T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 2, 4, 4, 4, null, '2026-05-04T12:00:00.000Z', '2026-05-04T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 4, 4, 3, 'Decent but the hand dryer was broken.', '2026-09-22T12:00:00.000Z', '2026-09-22T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 3, 3, 'Busy at lunch, restrooms so-so.', '2026-06-07T12:00:00.000Z', '2026-06-07T12:00:00.000Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 3, 4, 3, 3, 'Okay, could use more paper towels.', '2026-06-17T12:00:00.000Z', '2026-06-17T12:00:00.000Z'),
  ('f5ce41a7-6277-4bc4-a631-758d414c8773', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 3, 3, 'Decent but the hand dryer was broken.', '2026-04-06T12:00:00.000Z', '2026-04-06T12:00:00.000Z'),
  ('f5ce41a7-6277-4bc4-a631-758d414c8773', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 4, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-08-16T12:00:00.000Z', '2026-08-16T12:00:00.000Z'),
  ('f5ce41a7-6277-4bc4-a631-758d414c8773', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 3, 3, 3, null, '2026-05-06T12:00:00.000Z', '2026-05-06T12:00:00.000Z'),
  ('f5ce41a7-6277-4bc4-a631-758d414c8773', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 3, 3, 3, 'Okay, could use more paper towels.', '2026-08-27T12:00:00.000Z', '2026-08-27T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 4, 4, 'Spotless and well lit at night.', '2026-05-08T12:00:00.000Z', '2026-05-08T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 3, 3, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-09-21T12:00:00.000Z', '2026-09-21T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 4, 4, 4, null, '2026-10-03T12:00:00.000Z', '2026-10-03T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 4, 3, 3, 3, 'Okay, could use more paper towels.', '2026-05-12T12:00:00.000Z', '2026-05-12T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 3, 4, 4, 'Spotless and well lit at night.', '2026-05-25T12:00:00.000Z', '2026-05-25T12:00:00.000Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 2, 4, 3, 4, null, '2026-09-02T12:00:00.000Z', '2026-09-02T12:00:00.000Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 2, 1, 2, 1, null, '2026-05-17T12:00:00.000Z', '2026-05-17T12:00:00.000Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', '44271939-51f9-45d8-a7fc-f8da7217ef85', 2, 3, 2, 2, 'Needs cleaning badly.', '2026-06-10T12:00:00.000Z', '2026-06-10T12:00:00.000Z'),
  ('2ece299d-88b7-498b-a6c4-1c3fb96299a0', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 4, 4, 5, 'Clean, stocked, easy in and out.', '2026-08-05T12:00:00.000Z', '2026-08-05T12:00:00.000Z'),
  ('2ece299d-88b7-498b-a6c4-1c3fb96299a0', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 4, 5, 'Staff keeps it tidy. Plenty of parking.', '2026-06-06T12:00:00.000Z', '2026-06-06T12:00:00.000Z'),
  ('2ece299d-88b7-498b-a6c4-1c3fb96299a0', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 5, 4, 4, 'Family restroom was clean, changing table worked.', '2026-08-15T12:00:00.000Z', '2026-08-15T12:00:00.000Z'),
  ('2ece299d-88b7-498b-a6c4-1c3fb96299a0', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 5, 5, 5, 'Best stop on this stretch.', '2026-08-19T12:00:00.000Z', '2026-08-19T12:00:00.000Z'),
  ('2ece299d-88b7-498b-a6c4-1c3fb96299a0', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 5, 4, 5, 5, null, '2026-09-08T12:00:00.000Z', '2026-09-08T12:00:00.000Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'f703b145-ef45-4c25-a98b-139ca4c55886', 5, 5, 5, 4, 'Clean, stocked, easy in and out.', '2026-06-07T12:00:00.000Z', '2026-06-07T12:00:00.000Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 4, 4, 5, null, '2026-05-15T12:00:00.000Z', '2026-05-15T12:00:00.000Z'),
  ('18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 5, 4, null, '2026-03-31T12:00:00.000Z', '2026-03-31T12:00:00.000Z'),
  ('18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 5, 5, 4, 4, 'Family restroom was clean, changing table worked.', '2026-04-17T12:00:00.000Z', '2026-04-17T12:00:00.000Z'),
  ('18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 5, 5, 4, 5, 'Clean, stocked, easy in and out.', '2026-04-08T12:00:00.000Z', '2026-04-08T12:00:00.000Z'),
  ('18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 5, 4, 5, 'Safe feeling at 2am, lots of lights.', '2026-07-29T12:00:00.000Z', '2026-07-29T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 3, 3, 4, 'Family restroom was clean, changing table worked.', '2026-09-15T12:00:00.000Z', '2026-09-15T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 3, 3, 3, 'Fine for a quick stop.', '2026-09-26T12:00:00.000Z', '2026-09-26T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 4, 4, null, '2026-06-19T12:00:00.000Z', '2026-06-19T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 4, 3, 'Busy at lunch, restrooms so-so.', '2026-08-11T12:00:00.000Z', '2026-08-11T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 4, 4, 3, null, '2026-08-23T12:00:00.000Z', '2026-08-23T12:00:00.000Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 2, 3, 4, 3, 'Fine for a quick stop.', '2026-10-03T12:00:00.000Z', '2026-10-03T12:00:00.000Z'),
  ('07b5a3ab-0aec-40c4-ac14-aad41e9052d7', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 1, 2, 2, 2, 'Needs cleaning badly.', '2026-05-22T12:00:00.000Z', '2026-05-22T12:00:00.000Z'),
  ('07b5a3ab-0aec-40c4-ac14-aad41e9052d7', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 1, 3, 2, 3, 'Decent but the hand dryer was broken.', '2026-09-22T12:00:00.000Z', '2026-09-22T12:00:00.000Z'),
  ('07b5a3ab-0aec-40c4-ac14-aad41e9052d7', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 2, 2, 2, 2, null, '2026-08-05T12:00:00.000Z', '2026-08-05T12:00:00.000Z'),
  ('07b5a3ab-0aec-40c4-ac14-aad41e9052d7', '44271939-51f9-45d8-a7fc-f8da7217ef85', 2, 2, 2, 2, null, '2026-08-01T12:00:00.000Z', '2026-08-01T12:00:00.000Z'),
  ('07b5a3ab-0aec-40c4-ac14-aad41e9052d7', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 2, 2, 2, 3, null, '2026-08-09T12:00:00.000Z', '2026-08-09T12:00:00.000Z'),
  ('c418721a-85a3-4003-a5ee-9f8e80ed4a65', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 4, 4, 3, 'Fine for a quick stop.', '2026-09-14T12:00:00.000Z', '2026-09-14T12:00:00.000Z'),
  ('c418721a-85a3-4003-a5ee-9f8e80ed4a65', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 4, 3, 3, null, '2026-03-26T12:00:00.000Z', '2026-03-26T12:00:00.000Z'),
  ('c418721a-85a3-4003-a5ee-9f8e80ed4a65', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 3, 4, 'Clean, stocked, easy in and out.', '2026-09-19T12:00:00.000Z', '2026-09-19T12:00:00.000Z'),
  ('c418721a-85a3-4003-a5ee-9f8e80ed4a65', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 3, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-02T12:00:00.000Z', '2026-05-02T12:00:00.000Z'),
  ('c418721a-85a3-4003-a5ee-9f8e80ed4a65', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 3, 4, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-07-25T12:00:00.000Z', '2026-07-25T12:00:00.000Z'),
  ('a7ad1946-101a-4969-a9e1-d739b85a1e9c', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 5, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-08-18T12:00:00.000Z', '2026-08-18T12:00:00.000Z'),
  ('a7ad1946-101a-4969-a9e1-d739b85a1e9c', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 5, 5, 4, 'Best stop on this stretch.', '2026-08-03T12:00:00.000Z', '2026-08-03T12:00:00.000Z'),
  ('a7ad1946-101a-4969-a9e1-d739b85a1e9c', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 5, 4, 5, 'Staff keeps it tidy. Plenty of parking.', '2026-10-05T12:00:00.000Z', '2026-10-05T12:00:00.000Z'),
  ('a7ad1946-101a-4969-a9e1-d739b85a1e9c', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 4, 5, 4, 'Spotless and well lit at night.', '2026-04-04T12:00:00.000Z', '2026-04-04T12:00:00.000Z'),
  ('a7ad1946-101a-4969-a9e1-d739b85a1e9c', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 5, 4, 5, null, '2026-05-27T12:00:00.000Z', '2026-05-27T12:00:00.000Z'),
  ('2f377044-7f84-4d16-a631-909380d0066b', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 3, 3, 4, null, '2026-09-04T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('2f377044-7f84-4d16-a631-909380d0066b', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 2, 3, 4, 2, null, '2026-06-20T12:00:00.000Z', '2026-06-20T12:00:00.000Z'),
  ('2f377044-7f84-4d16-a631-909380d0066b', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 3, 4, 3, 'Busy at lunch, restrooms so-so.', '2026-09-08T12:00:00.000Z', '2026-09-08T12:00:00.000Z'),
  ('2f377044-7f84-4d16-a631-909380d0066b', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 3, 3, 'Okay, could use more paper towels.', '2026-05-07T12:00:00.000Z', '2026-05-07T12:00:00.000Z'),
  ('2f377044-7f84-4d16-a631-909380d0066b', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-07-16T12:00:00.000Z', '2026-07-16T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 3, 4, 3, null, '2026-06-21T12:00:00.000Z', '2026-06-21T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 4, 4, 4, null, '2026-07-19T12:00:00.000Z', '2026-07-19T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 4, 4, 3, null, '2026-07-09T12:00:00.000Z', '2026-07-09T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 4, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-27T12:00:00.000Z', '2026-05-27T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 2, 4, 3, 3, 'Fine for a quick stop.', '2026-08-08T12:00:00.000Z', '2026-08-08T12:00:00.000Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 4, 4, 3, null, '2026-08-09T12:00:00.000Z', '2026-08-09T12:00:00.000Z'),
  ('d2516c62-2ea9-4870-a7ee-2f4a4c5643e0', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 3, 3, 4, null, '2026-06-21T12:00:00.000Z', '2026-06-21T12:00:00.000Z'),
  ('d2516c62-2ea9-4870-a7ee-2f4a4c5643e0', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 3, 3, 3, 'Okay, could use more paper towels.', '2026-06-28T12:00:00.000Z', '2026-06-28T12:00:00.000Z'),
  ('d2516c62-2ea9-4870-a7ee-2f4a4c5643e0', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 4, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-21T12:00:00.000Z', '2026-05-21T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 4, 3, 4, 4, 'Best stop on this stretch.', '2026-07-27T12:00:00.000Z', '2026-07-27T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 3, 3, 3, 'Decent but the hand dryer was broken.', '2026-09-09T12:00:00.000Z', '2026-09-09T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 3, 3, 4, 'Spotless and well lit at night.', '2026-05-14T12:00:00.000Z', '2026-05-14T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 3, 4, 'Clean, stocked, easy in and out.', '2026-04-17T12:00:00.000Z', '2026-04-17T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 2, 3, null, '2026-09-23T12:00:00.000Z', '2026-09-23T12:00:00.000Z'),
  ('7ab421c5-d390-4d40-ab66-87eaa267f363', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 3, 4, 4, 'Clean, stocked, easy in and out.', '2026-05-24T12:00:00.000Z', '2026-05-24T12:00:00.000Z'),
  ('77cd3209-e943-4b5f-a4c2-03c0efc022e1', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 3, 3, 3, 'Busy at lunch, restrooms so-so.', '2026-08-19T12:00:00.000Z', '2026-08-19T12:00:00.000Z'),
  ('eccb633a-9c2b-4c61-ad5c-dd786f55ae33', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 4, 3, 4, 'Spotless and well lit at night.', '2026-07-09T12:00:00.000Z', '2026-07-09T12:00:00.000Z'),
  ('eccb633a-9c2b-4c61-ad5c-dd786f55ae33', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 3, 3, 3, 'Decent but the hand dryer was broken.', '2026-09-15T12:00:00.000Z', '2026-09-15T12:00:00.000Z'),
  ('eccb633a-9c2b-4c61-ad5c-dd786f55ae33', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 3, 3, null, '2026-06-03T12:00:00.000Z', '2026-06-03T12:00:00.000Z'),
  ('eccb633a-9c2b-4c61-ad5c-dd786f55ae33', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 3, 4, 4, 'Best stop on this stretch.', '2026-03-29T12:00:00.000Z', '2026-03-29T12:00:00.000Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 5, 5, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-05-28T12:00:00.000Z', '2026-05-28T12:00:00.000Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 5, 5, null, '2026-07-25T12:00:00.000Z', '2026-07-25T12:00:00.000Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 5, 5, 5, 4, 'Family restroom was clean, changing table worked.', '2026-04-24T12:00:00.000Z', '2026-04-24T12:00:00.000Z'),
  ('69ffd908-9d4f-4d12-a996-c02f2c879c20', '44271939-51f9-45d8-a7fc-f8da7217ef85', 4, 4, 4, 5, 'Staff keeps it tidy. Plenty of parking.', '2026-05-20T12:00:00.000Z', '2026-05-20T12:00:00.000Z'),
  ('69ffd908-9d4f-4d12-a996-c02f2c879c20', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 5, 5, 5, 'Family restroom was clean, changing table worked.', '2026-06-30T12:00:00.000Z', '2026-06-30T12:00:00.000Z'),
  ('69ffd908-9d4f-4d12-a996-c02f2c879c20', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 4, 4, 4, 4, 'Spotless and well lit at night.', '2026-10-02T12:00:00.000Z', '2026-10-02T12:00:00.000Z'),
  ('69ffd908-9d4f-4d12-a996-c02f2c879c20', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 5, 5, 4, 'Spotless and well lit at night.', '2026-08-02T12:00:00.000Z', '2026-08-02T12:00:00.000Z'),
  ('831472bb-d054-4490-a918-f3a87b3aeff5', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 4, 4, 4, 'Clean, stocked, easy in and out.', '2026-07-10T12:00:00.000Z', '2026-07-10T12:00:00.000Z'),
  ('a4ae93aa-bc1b-48dd-adef-9dab34e2e90d', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 4, 4, 4, null, '2026-05-13T12:00:00.000Z', '2026-05-13T12:00:00.000Z'),
  ('a4ae93aa-bc1b-48dd-adef-9dab34e2e90d', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 4, 3, 2, 2, null, '2026-07-01T12:00:00.000Z', '2026-07-01T12:00:00.000Z'),
  ('a4ae93aa-bc1b-48dd-adef-9dab34e2e90d', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 3, 3, 4, 3, null, '2026-05-05T12:00:00.000Z', '2026-05-05T12:00:00.000Z'),
  ('a4ae93aa-bc1b-48dd-adef-9dab34e2e90d', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 3, 4, 3, null, '2026-07-07T12:00:00.000Z', '2026-07-07T12:00:00.000Z'),
  ('6a8145ec-fbf8-4515-ae17-845cf6c17fd8', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 4, 4, 'Staff keeps it tidy. Plenty of parking.', '2026-04-07T12:00:00.000Z', '2026-04-07T12:00:00.000Z'),
  ('6a8145ec-fbf8-4515-ae17-845cf6c17fd8', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 3, 3, 4, 4, null, '2026-09-04T12:00:00.000Z', '2026-09-04T12:00:00.000Z'),
  ('6a8145ec-fbf8-4515-ae17-845cf6c17fd8', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 4, 4, 3, 2, 'Dark lot, would not stop at night.', '2026-05-14T12:00:00.000Z', '2026-05-14T12:00:00.000Z'),
  ('6a8145ec-fbf8-4515-ae17-845cf6c17fd8', '44271939-51f9-45d8-a7fc-f8da7217ef85', 3, 3, 2, 3, 'Fine for a quick stop.', '2026-08-30T12:00:00.000Z', '2026-08-30T12:00:00.000Z'),
  ('fee4a600-35a2-465e-ae23-0c0c97e18bbc', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 4, 3, 4, 'Safe feeling at 2am, lots of lights.', '2026-03-30T12:00:00.000Z', '2026-03-30T12:00:00.000Z'),
  ('fee4a600-35a2-465e-ae23-0c0c97e18bbc', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 4, 3, 3, null, '2026-10-01T12:00:00.000Z', '2026-10-01T12:00:00.000Z'),
  ('fee4a600-35a2-465e-ae23-0c0c97e18bbc', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 3, 3, 3, 4, null, '2026-10-04T12:00:00.000Z', '2026-10-04T12:00:00.000Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', '44271939-51f9-45d8-a7fc-f8da7217ef85', 2, 2, 2, 3, 'Okay, could use more paper towels.', '2026-06-21T12:00:00.000Z', '2026-06-21T12:00:00.000Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', 2, 3, 2, 3, null, '2026-09-26T12:00:00.000Z', '2026-09-26T12:00:00.000Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'f703b145-ef45-4c25-a98b-139ca4c55886', 2, 1, 3, 2, 'Needs cleaning badly.', '2026-08-13T12:00:00.000Z', '2026-08-13T12:00:00.000Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 2, 2, 3, 3, 'Fine for a quick stop.', '2026-03-28T12:00:00.000Z', '2026-03-28T12:00:00.000Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 2, 3, 2, 3, 'Fine for a quick stop.', '2026-08-01T12:00:00.000Z', '2026-08-01T12:00:00.000Z'),
  ('39f955e1-c343-459c-a1e4-6e25aada3514', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 3, 3, 3, 4, 'Spotless and well lit at night.', '2026-05-31T12:00:00.000Z', '2026-05-31T12:00:00.000Z'),
  ('39f955e1-c343-459c-a1e4-6e25aada3514', 'f703b145-ef45-4c25-a98b-139ca4c55886', 3, 3, 2, 4, null, '2026-05-07T12:00:00.000Z', '2026-05-07T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 2, 2, 1, 3, 'Busy at lunch, restrooms so-so.', '2026-06-21T12:00:00.000Z', '2026-06-21T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', 'f703b145-ef45-4c25-a98b-139ca4c55886', 2, 1, 1, 1, 'Needs cleaning badly.', '2026-04-20T12:00:00.000Z', '2026-04-20T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', '44271939-51f9-45d8-a7fc-f8da7217ef85', 1, 2, 1, 2, null, '2026-05-01T12:00:00.000Z', '2026-05-01T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 2, 2, 3, 2, 'Needs cleaning badly.', '2026-05-09T12:00:00.000Z', '2026-05-09T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 3, 2, 2, 2, 'Needs cleaning badly.', '2026-07-02T12:00:00.000Z', '2026-07-02T12:00:00.000Z'),
  ('4f35c002-ef64-44f4-a905-64d28697d0fa', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 2, 2, 2, 2, 'Dark lot, would not stop at night.', '2026-04-20T12:00:00.000Z', '2026-04-20T12:00:00.000Z'),
  ('1b4f54fd-a331-4264-a020-c42f15d574a1', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 2, 2, 2, 2, 'Out of soap and paper.', '2026-05-19T12:00:00.000Z', '2026-05-19T12:00:00.000Z'),
  ('a6d93f76-0c04-485c-ade7-1d4e28d40b9d', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 5, 4, 3, 4, 'Safe feeling at 2am, lots of lights.', '2026-05-29T12:00:00.000Z', '2026-05-29T12:00:00.000Z'),
  ('a6d93f76-0c04-485c-ade7-1d4e28d40b9d', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 5, 4, 5, 3, null, '2026-08-05T12:00:00.000Z', '2026-08-05T12:00:00.000Z'),
  ('a6d93f76-0c04-485c-ade7-1d4e28d40b9d', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 5, 4, 5, 3, 'Okay, could use more paper towels.', '2026-08-22T12:00:00.000Z', '2026-08-22T12:00:00.000Z'),
  ('a6d93f76-0c04-485c-ade7-1d4e28d40b9d', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 4, 4, 5, 5, 'Best stop on this stretch.', '2026-06-23T12:00:00.000Z', '2026-06-23T12:00:00.000Z'),
  ('a6d93f76-0c04-485c-ade7-1d4e28d40b9d', 'f703b145-ef45-4c25-a98b-139ca4c55886', 5, 4, 5, 4, null, '2026-05-12T12:00:00.000Z', '2026-05-12T12:00:00.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 2, 4, 4, 4, 'Family restroom was clean, changing table worked.', '2026-09-27T12:00:00.000Z', '2026-09-27T12:00:00.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'f703b145-ef45-4c25-a98b-139ca4c55886', 4, 3, 3, 3, 'Decent but the hand dryer was broken.', '2026-08-13T12:00:00.000Z', '2026-08-13T12:00:00.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 3, 3, 4, 3, null, '2026-06-22T12:00:00.000Z', '2026-06-22T12:00:00.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 3, 4, 3, 4, 'Family restroom was clean, changing table worked.', '2026-08-13T12:00:00.000Z', '2026-08-13T12:00:00.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', '4e4e7cb4-e80a-4817-a563-d3ff7062761a', 3, 3, 3, 3, 'Busy at lunch, restrooms so-so.', '2026-06-26T12:00:00.000Z', '2026-06-26T12:00:00.000Z'),
  ('27fca49b-e619-4b8a-a575-52ecd7a9d5aa', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 4, 5, 5, 3, 'Okay, could use more paper towels.', '2026-06-23T12:00:00.000Z', '2026-06-23T12:00:00.000Z'),
  ('27fca49b-e619-4b8a-a575-52ecd7a9d5aa', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 5, 3, 4, 4, 'Clean, stocked, easy in and out.', '2026-05-15T12:00:00.000Z', '2026-05-15T12:00:00.000Z'),
  ('27fca49b-e619-4b8a-a575-52ecd7a9d5aa', 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', 5, 3, 4, 4, 'Safe feeling at 2am, lots of lights.', '2026-08-19T12:00:00.000Z', '2026-08-19T12:00:00.000Z'),
  ('27fca49b-e619-4b8a-a575-52ecd7a9d5aa', '44271939-51f9-45d8-a7fc-f8da7217ef85', 5, 5, 4, 5, null, '2026-10-01T12:00:00.000Z', '2026-10-01T12:00:00.000Z');

insert into public.fuel_prices (location_id, grade, price, reported_by, reported_at) values
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'regular', 3.009, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-06T14:12:31.534Z'),
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'midgrade', 3.459, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-06T14:12:31.534Z'),
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'premium', 3.859, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-06T14:12:31.534Z'),
  ('cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c', 'diesel', 3.587, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-06T14:12:31.534Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'regular', 3.139, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-07T04:23:34.647Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'midgrade', 3.589, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T04:23:34.647Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'premium', 3.989, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-07T04:23:34.647Z'),
  ('3c4b490b-1194-44a2-a2ef-3de040336bcc', 'diesel', 3.782, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-07T04:23:34.647Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', 'regular', 2.949, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-07T21:54:37.994Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', 'midgrade', 3.399, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T21:54:37.994Z'),
  ('36e8740f-1870-4077-a68a-dc3b99c3fb63', 'premium', 3.799, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-07T21:54:37.994Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'regular', 2.939, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-09-26T17:27:10.368Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'midgrade', 3.389, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-09-26T17:27:10.368Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'premium', 3.789, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-09-26T17:27:10.368Z'),
  ('2e189d6e-4bf0-4971-ac22-ac7bf08b1d45', 'diesel', 3.467, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-09-26T17:27:10.368Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'regular', 2.989, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-07T03:28:22.292Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'midgrade', 3.439, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-07T03:28:22.292Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'premium', 3.839, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-07T03:28:22.292Z'),
  ('f3e6f617-f5a0-40a2-a237-87fc33af539a', 'diesel', 3.665, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T03:28:22.292Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'regular', 3.269, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-03T17:39:37.126Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'midgrade', 3.719, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-03T17:39:37.126Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'premium', 4.119, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-03T17:39:37.126Z'),
  ('f74ab562-6257-41f8-aa81-d9ecaf84a18a', 'diesel', 3.904, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-03T17:39:37.126Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'regular', 3.189, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-05T05:07:12.973Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'midgrade', 3.639, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-05T05:07:12.973Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'premium', 4.039, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-05T05:07:12.973Z'),
  ('022b6396-428b-494e-ac36-a5fa8f47de4c', 'diesel', 3.86, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-05T05:07:12.973Z'),
  ('37992196-64a0-48a7-a2e4-9b749d405273', 'regular', 2.909, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-07T10:44:34.579Z'),
  ('37992196-64a0-48a7-a2e4-9b749d405273', 'midgrade', 3.359, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-07T10:44:34.579Z'),
  ('37992196-64a0-48a7-a2e4-9b749d405273', 'premium', 3.759, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-07T10:44:34.579Z'),
  ('37992196-64a0-48a7-a2e4-9b749d405273', 'diesel', 3.443, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-07T10:44:34.579Z'),
  ('aa8ccc30-a214-44f0-af6c-c067b349d650', 'regular', 2.989, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T11:22:58.240Z'),
  ('aa8ccc30-a214-44f0-af6c-c067b349d650', 'midgrade', 3.439, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-07T11:22:58.240Z'),
  ('aa8ccc30-a214-44f0-af6c-c067b349d650', 'premium', 3.839, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-07T11:22:58.240Z'),
  ('aa8ccc30-a214-44f0-af6c-c067b349d650', 'diesel', 3.7, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-07T11:22:58.240Z'),
  ('7bf04df7-bb52-4cc4-a07f-834249d0700f', 'regular', 2.879, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-04T13:48:20.226Z'),
  ('7bf04df7-bb52-4cc4-a07f-834249d0700f', 'midgrade', 3.329, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-04T13:48:20.226Z'),
  ('7bf04df7-bb52-4cc4-a07f-834249d0700f', 'premium', 3.729, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-04T13:48:20.226Z'),
  ('7bf04df7-bb52-4cc4-a07f-834249d0700f', 'diesel', 3.54, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-04T13:48:20.226Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'regular', 3.149, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-09-11T18:35:41.829Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'midgrade', 3.599, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-09-11T18:35:41.829Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'premium', 3.999, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-09-11T18:35:41.829Z'),
  ('ca6d8989-0c0c-4f05-ac43-479d15d4a7d9', 'diesel', 3.845, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-09-11T18:35:41.829Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'regular', 3.019, '9874c592-8d3c-4f66-a66a-e3535c3594fd', '2026-10-05T20:58:39.412Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'midgrade', 3.469, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-05T20:58:39.412Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'premium', 3.869, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-05T20:58:39.412Z'),
  ('743ebdc0-efc0-4c41-a19a-9b67a354a4c7', 'diesel', 3.544, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-05T20:58:39.412Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'regular', 3.139, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-08T00:07:58.176Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'midgrade', 3.589, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-08T00:07:58.176Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'premium', 3.989, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-08T00:07:58.176Z'),
  ('c2ff4563-b54c-477e-af37-8da3c0aa4b36', 'diesel', 3.775, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-08T00:07:58.176Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'regular', 3.269, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-07T04:02:18.980Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'midgrade', 3.719, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-07T04:02:18.980Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'premium', 4.119, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-07T04:02:18.980Z'),
  ('b9f83b4f-95af-46d6-a99b-cfdac54d43f1', 'diesel', 3.878, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-07T04:02:18.980Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'regular', 3.199, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-09-26T11:38:53.440Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'midgrade', 3.649, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-09-26T11:38:53.440Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'premium', 4.049, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-09-26T11:38:53.440Z'),
  ('dfab0b80-6065-43b8-aafa-937c57807f27', 'diesel', 3.844, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-09-26T11:38:53.440Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'regular', 2.749, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-07T15:21:01.089Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'midgrade', 3.199, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T15:21:01.089Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'premium', 3.599, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-07T15:21:01.089Z'),
  ('b420c2bb-d8b6-4d79-a5a6-32de62a417c8', 'diesel', 3.378, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-07T15:21:01.089Z'),
  ('77cd3209-e943-4b5f-a4c2-03c0efc022e1', 'regular', 2.799, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-06T18:40:29.254Z'),
  ('77cd3209-e943-4b5f-a4c2-03c0efc022e1', 'midgrade', 3.249, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-06T18:40:29.254Z'),
  ('77cd3209-e943-4b5f-a4c2-03c0efc022e1', 'premium', 3.649, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-06T18:40:29.254Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'regular', 2.949, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-07T22:42:58.787Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'midgrade', 3.399, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-07T22:42:58.787Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'premium', 3.799, 'dd6a4732-5bfa-40b1-a941-42c3a7a74db2', '2026-10-07T22:42:58.787Z'),
  ('464bd7a3-5b35-489e-a3a1-f9d7cc3425da', 'diesel', 3.64, '44271939-51f9-45d8-a7fc-f8da7217ef85', '2026-10-07T22:42:58.787Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'regular', 3.429, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-09-18T01:35:01.736Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'midgrade', 3.879, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-09-18T01:35:01.736Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'premium', 4.279, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-09-18T01:35:01.736Z'),
  ('5abfe274-8135-4073-a8a1-c6c449aac7ac', 'diesel', 4.048, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-09-18T01:35:01.736Z'),
  ('4eaafb81-f19b-41c9-af91-a66c22c09ef5', 'regular', 3.449, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-07T10:37:01.470Z'),
  ('4eaafb81-f19b-41c9-af91-a66c22c09ef5', 'midgrade', 3.899, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-07T10:37:01.470Z'),
  ('4eaafb81-f19b-41c9-af91-a66c22c09ef5', 'premium', 4.299, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-07T10:37:01.470Z'),
  ('4eaafb81-f19b-41c9-af91-a66c22c09ef5', 'diesel', 4.096, '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', '2026-10-07T10:37:01.470Z'),
  ('a3785304-3931-4990-a970-8ece22f22f14', 'regular', 3.339, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-04T16:59:01.000Z'),
  ('a3785304-3931-4990-a970-8ece22f22f14', 'midgrade', 3.789, 'b2991232-cc12-45cc-ad8b-b2c6ae1512cb', '2026-10-04T16:59:01.000Z'),
  ('a3785304-3931-4990-a970-8ece22f22f14', 'premium', 4.189, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-04T16:59:01.000Z'),
  ('a3785304-3931-4990-a970-8ece22f22f14', 'diesel', 3.971, 'f4face4f-884c-49bf-a971-0b6adaa0d65f', '2026-10-04T16:59:01.000Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'regular', 3.599, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-08T06:53:17.762Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'midgrade', 4.049, '4e4e7cb4-e80a-4817-a563-d3ff7062761a', '2026-10-08T06:53:17.762Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'premium', 4.449, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-08T06:53:17.762Z'),
  ('4b6d4915-ec40-42aa-a0cc-3e946883c3ed', 'diesel', 4.243, 'f703b145-ef45-4c25-a98b-139ca4c55886', '2026-10-08T06:53:17.762Z');

insert into public.reports (location_id, user_id, issue, note, created_at) values
  ('32eb6feb-43a3-4d66-a121-f3c1d7ae4031', '7a53ab8c-5b8d-472d-a1e9-0b7d74def558', 'no_supplies', 'No toilet paper in the men''s room', '2026-10-07T12:00:00.000Z'),
  ('15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad', 'f4face4f-884c-49bf-a971-0b6adaa0d65f', 'out_of_order', 'Two of three stalls out of order', '2026-10-06T12:00:00.000Z'),
  ('5df80887-7463-4c0a-adcb-e6524750d48c', '9874c592-8d3c-4f66-a66a-e3535c3594fd', 'closed', 'Closed for renovation, fenced off', '2026-10-05T12:00:00.000Z');

-- The last-verified stamps above are part of the sample; keep them after the triggers ran.
update public.locations set last_verified_at = '2026-08-28T12:00:00.000Z' where id = 'f2c389ec-8602-40ff-abd3-3aa288e30187';
update public.locations set last_verified_at = '2026-09-21T12:00:00.000Z' where id = 'cc0b53b3-95ab-4c7b-ae5c-d7f085c2972c';
update public.locations set last_verified_at = '2026-09-13T12:00:00.000Z' where id = '3c4b490b-1194-44a2-a2ef-3de040336bcc';
update public.locations set last_verified_at = '2026-09-21T12:00:00.000Z' where id = '36e8740f-1870-4077-a68a-dc3b99c3fb63';
update public.locations set last_verified_at = '2026-09-24T12:00:00.000Z' where id = '2e189d6e-4bf0-4971-ac22-ac7bf08b1d45';
update public.locations set last_verified_at = '2026-09-27T12:00:00.000Z' where id = 'f3e6f617-f5a0-40a2-a237-87fc33af539a';
update public.locations set last_verified_at = '2026-09-10T12:00:00.000Z' where id = 'f74ab562-6257-41f8-aa81-d9ecaf84a18a';
update public.locations set last_verified_at = '2026-09-01T12:00:00.000Z' where id = '32eb6feb-43a3-4d66-a121-f3c1d7ae4031';
update public.locations set last_verified_at = '2026-09-04T12:00:00.000Z' where id = 'e73eab24-9608-4d36-aa89-6abb008d9a39';
update public.locations set last_verified_at = '2026-09-16T12:00:00.000Z' where id = '022b6396-428b-494e-ac36-a5fa8f47de4c';
update public.locations set last_verified_at = '2026-07-02T12:00:00.000Z' where id = '37992196-64a0-48a7-a2e4-9b749d405273';
update public.locations set last_verified_at = '2026-09-15T12:00:00.000Z' where id = 'aa8ccc30-a214-44f0-af6c-c067b349d650';
update public.locations set last_verified_at = '2026-10-03T12:00:00.000Z' where id = 'f00daec8-e853-4a78-a382-2940ac50f911';
update public.locations set last_verified_at = '2026-09-14T12:00:00.000Z' where id = '16d581a6-ff64-450e-ac7f-3ac44526f7d1';
update public.locations set last_verified_at = '2026-10-02T12:00:00.000Z' where id = '0666a080-857d-45ea-a272-58a91589a143';
update public.locations set last_verified_at = '2026-09-21T12:00:00.000Z' where id = '537d1367-14f0-4a18-ab1b-ee5015617612';
update public.locations set last_verified_at = '2026-06-23T12:00:00.000Z' where id = '386e3186-90a0-4314-a22a-4ff01b316db1';
update public.locations set last_verified_at = '2026-09-29T12:00:00.000Z' where id = '7bf04df7-bb52-4cc4-a07f-834249d0700f';
update public.locations set last_verified_at = '2026-08-27T12:00:00.000Z' where id = '15e48bf0-f2b0-4acb-a2af-cc7bc505f1ad';
update public.locations set last_verified_at = '2026-08-26T12:00:00.000Z' where id = 'ca6d8989-0c0c-4f05-ac43-479d15d4a7d9';
update public.locations set last_verified_at = '2026-01-27T12:00:00.000Z' where id = 'e652fe83-f588-4e4d-a3e1-e16741f40e85';
update public.locations set last_verified_at = '2026-10-06T12:00:00.000Z' where id = '9e73f084-488f-40ba-a30e-0e6d8f931cbf';
update public.locations set last_verified_at = '2026-02-02T12:00:00.000Z' where id = 'f5ce41a7-6277-4bc4-a631-758d414c8773';
update public.locations set last_verified_at = '2026-04-05T12:00:00.000Z' where id = '743ebdc0-efc0-4c41-a19a-9b67a354a4c7';
update public.locations set last_verified_at = '2026-09-15T12:00:00.000Z' where id = 'c2ff4563-b54c-477e-af37-8da3c0aa4b36';
update public.locations set last_verified_at = '2026-09-23T12:00:00.000Z' where id = '2ece299d-88b7-498b-a6c4-1c3fb96299a0';
update public.locations set last_verified_at = '2026-09-05T12:00:00.000Z' where id = 'b9f83b4f-95af-46d6-a99b-cfdac54d43f1';
update public.locations set last_verified_at = '2026-09-30T12:00:00.000Z' where id = '18dc78d7-bf7b-48a1-a53a-2f25b64ad5bc';
update public.locations set last_verified_at = '2026-02-24T12:00:00.000Z' where id = 'dfab0b80-6065-43b8-aafa-937c57807f27';
update public.locations set last_verified_at = '2026-09-05T12:00:00.000Z' where id = '5df80887-7463-4c0a-adcb-e6524750d48c';
update public.locations set last_verified_at = '2026-09-25T12:00:00.000Z' where id = '07b5a3ab-0aec-40c4-ac14-aad41e9052d7';
update public.locations set last_verified_at = '2026-09-20T12:00:00.000Z' where id = 'c418721a-85a3-4003-a5ee-9f8e80ed4a65';
update public.locations set last_verified_at = '2026-01-22T12:00:00.000Z' where id = 'a7ad1946-101a-4969-a9e1-d739b85a1e9c';
update public.locations set last_verified_at = '2026-08-29T12:00:00.000Z' where id = '2f377044-7f84-4d16-a631-909380d0066b';
update public.locations set last_verified_at = '2026-08-25T12:00:00.000Z' where id = '0fbc829a-950d-48ec-aaf1-2c25858f4eb8';
update public.locations set last_verified_at = '2026-03-27T12:00:00.000Z' where id = 'b420c2bb-d8b6-4d79-a5a6-32de62a417c8';
update public.locations set last_verified_at = '2026-09-30T12:00:00.000Z' where id = 'd2516c62-2ea9-4870-a7ee-2f4a4c5643e0';
update public.locations set last_verified_at = '2026-09-18T12:00:00.000Z' where id = '7ab421c5-d390-4d40-ab66-87eaa267f363';
update public.locations set last_verified_at = '2026-09-14T12:00:00.000Z' where id = '77cd3209-e943-4b5f-a4c2-03c0efc022e1';
update public.locations set last_verified_at = '2026-09-20T12:00:00.000Z' where id = 'eccb633a-9c2b-4c61-ad5c-dd786f55ae33';
update public.locations set last_verified_at = '2026-08-28T12:00:00.000Z' where id = '464bd7a3-5b35-489e-a3a1-f9d7cc3425da';
update public.locations set last_verified_at = '2026-02-26T12:00:00.000Z' where id = '69ffd908-9d4f-4d12-a996-c02f2c879c20';
update public.locations set last_verified_at = '2026-09-18T12:00:00.000Z' where id = '831472bb-d054-4490-a918-f3a87b3aeff5';
update public.locations set last_verified_at = '2026-09-29T12:00:00.000Z' where id = 'a4ae93aa-bc1b-48dd-adef-9dab34e2e90d';
update public.locations set last_verified_at = '2026-09-21T12:00:00.000Z' where id = '6a8145ec-fbf8-4515-ae17-845cf6c17fd8';
update public.locations set last_verified_at = '2026-09-27T12:00:00.000Z' where id = 'fee4a600-35a2-465e-ae23-0c0c97e18bbc';
update public.locations set last_verified_at = '2026-10-07T12:00:00.000Z' where id = '5abfe274-8135-4073-a8a1-c6c449aac7ac';
update public.locations set last_verified_at = '2026-09-04T12:00:00.000Z' where id = '4eaafb81-f19b-41c9-af91-a66c22c09ef5';
update public.locations set last_verified_at = '2026-09-14T12:00:00.000Z' where id = '39f955e1-c343-459c-a1e4-6e25aada3514';
update public.locations set last_verified_at = '2026-09-09T12:00:00.000Z' where id = 'a0ccb4d3-d3b5-4908-aaae-e4e1f2684a95';
update public.locations set last_verified_at = '2026-08-26T12:00:00.000Z' where id = '4f35c002-ef64-44f4-a905-64d28697d0fa';
update public.locations set last_verified_at = '2026-09-20T12:00:00.000Z' where id = '1b4f54fd-a331-4264-a020-c42f15d574a1';
update public.locations set last_verified_at = '2026-09-28T12:00:00.000Z' where id = 'a6d93f76-0c04-485c-ade7-1d4e28d40b9d';
update public.locations set last_verified_at = '2026-08-29T12:00:00.000Z' where id = 'a3785304-3931-4990-a970-8ece22f22f14';
update public.locations set last_verified_at = '2026-08-31T12:00:00.000Z' where id = '4b6d4915-ec40-42aa-a0cc-3e946883c3ed';
update public.locations set last_verified_at = '2026-08-30T12:00:00.000Z' where id = '27fca49b-e619-4b8a-a575-52ecd7a9d5aa';
commit;
