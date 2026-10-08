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
