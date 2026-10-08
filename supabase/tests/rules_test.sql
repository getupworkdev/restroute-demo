-- Behaviour tests for the schema. Run with: supabase/tests/run.sh
-- Each block acts as a given user (role + JWT subject), the way PostgREST does.
\set ON_ERROR_STOP 1
set client_min_messages = warning;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@test'),
  ('00000000-0000-0000-0000-00000000000b', 'b@test'),
  ('00000000-0000-0000-0000-00000000000c', 'c@test'),
  ('00000000-0000-0000-0000-00000000000d', 'admin@test');
update profiles set is_admin = true where id = '00000000-0000-0000-0000-00000000000d';

create function pg_temp.act(who text) returns void language plpgsql as $$
begin
  if who = 'anon' then
    perform set_config('request.jwt.claim.sub', '', false);
    execute 'set role anon';
  else
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000' || who, false);
    execute 'set role authenticated';
  end if;
end $$;
create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', what; end if;
  raise notice 'ok  %', what;
end $$;
grant execute on all functions in schema pg_temp to anon, authenticated;
set client_min_messages = notice;

-- Anonymous visitors can browse but not add.
select pg_temp.act('anon');
select pg_temp.check((select count(*) from locations) = 0, 'anon can read locations');
do $$ begin
  insert into locations (name, stop_type, geog, access) values ('x', 'park', 'SRID=4326;POINT(-84 34)', 'free');
  raise exception 'FAIL: anon inserted a location';
exception when insufficient_privilege then raise notice 'ok  anon cannot add a location';
end $$;
reset role;

-- A signed-in user adds a stop; the server-owned fields ignore what the client sent.
select pg_temp.act('a');
insert into locations (id, name, stop_type, geog, access, highway, rating_count, last_verified_at, moderation, gas, diesel)
values ('11111111-0000-0000-0000-000000000001', 'Exit 12 Rest Area', 'rest_area', 'SRID=4326;POINT(-84.39 34.00)',
        'free', ' i-75 ', 99, now() - interval '1 year', 'visible', 'yes', 'yes');
select pg_temp.check(
  (select rating_count = 0 and last_verified_at > now() - interval '1 minute' and highway = 'I-75'
          and created_by = auth.uid() and abs(lat - 34.0) < 1e-9 and abs(lng + 84.39) < 1e-9
     from locations where id = '11111111-0000-0000-0000-000000000001'),
  'insert resets server fields, normalises highway, derives lat/lng');
select pg_temp.check(
  (select gas = 'yes' and showers = 'unknown' from locations where id = '11111111-0000-0000-0000-000000000001'),
  'amenities default to unknown');
do $$ begin
  update locations set name = 'hacked' where id = '11111111-0000-0000-0000-000000000001';
  if (select name from locations where id = '11111111-0000-0000-0000-000000000001') = 'hacked' then
    raise exception 'FAIL: user edited a location directly';
  end if;
  raise notice 'ok  users cannot edit location rows directly';
end $$;

-- F4.1 ratings: averages kept by the database, one set per user, editable by its owner.
insert into ratings (location_id, clean, safety, supplies, overall, review)
values ('11111111-0000-0000-0000-000000000001', 4, 5, 3, 4, 'Clean, well lit');
do $$ begin
  insert into ratings (location_id, clean, safety, supplies, overall)
  values ('11111111-0000-0000-0000-000000000001', 1, 1, 1, 1);
  raise exception 'FAIL: second rating by same user';
exception when unique_violation then raise notice 'ok  one rating set per user per location';
end $$;
select pg_temp.act('b');
insert into ratings (location_id, clean, safety, supplies, overall)
values ('11111111-0000-0000-0000-000000000001', 2, 3, 1, 2);
select pg_temp.check(
  (select rating_count = 2 and avg_clean = 3 and avg_safety = 4 and avg_supplies = 2 and avg_overall = 3
     from locations where id = '11111111-0000-0000-0000-000000000001'),
  'averages and count across two users');
update ratings set clean = 5 where user_id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.check(
  (select avg_clean = 3 from locations where id = '11111111-0000-0000-0000-000000000001'),
  'user B cannot change user A''s rating');
select pg_temp.act('a');
update ratings set clean = 5 where user_id = auth.uid();
select pg_temp.check(
  (select avg_clean = 3.5 from locations where id = '11111111-0000-0000-0000-000000000001'),
  'owner edits own rating and the average follows');

-- F4.3 / F4.4: "closed" hides from default results until someone verifies it.
select pg_temp.act('b');
insert into reports (location_id, issue) values ('11111111-0000-0000-0000-000000000001', 'closed');
insert into reports (location_id, issue, note) values ('11111111-0000-0000-0000-000000000001', 'no_supplies', 'no paper');
select pg_temp.check(
  (select open_issues = '{closed,no_supplies}' from locations where id = '11111111-0000-0000-0000-000000000001'),
  'open issues listed on the location');
reset role;
update locations set last_verified_at = now() - interval '120 days' where id = '11111111-0000-0000-0000-000000000001';
select pg_temp.act('c');
select verify_location('11111111-0000-0000-0000-000000000001');
select pg_temp.check(
  (select open_issues = '{}' and last_verified_at > now() - interval '1 minute'
     from locations where id = '11111111-0000-0000-0000-000000000001'),
  '"still good" refreshes the stamp and resolves open reports');
select pg_temp.check(
  (select count(*) = 0 from reports where status = 'open'), 'reports marked resolved');
select pg_temp.act('anon');
do $$ begin
  perform verify_location('11111111-0000-0000-0000-000000000001');
  raise exception 'FAIL: anon verified';
exception when insufficient_privilege then raise notice 'ok  anon cannot verify';
end $$;

-- F5.6 fuel prices: latest per grade on the location, with its timestamp.
select pg_temp.act('a');
insert into fuel_prices (location_id, grade, price) values ('11111111-0000-0000-0000-000000000001', 'diesel', 3.899);
insert into fuel_prices (location_id, grade, price) values ('11111111-0000-0000-0000-000000000001', 'diesel', 3.799);
insert into fuel_prices (location_id, grade, price) values ('11111111-0000-0000-0000-000000000001', 'regular', 3.099);
select pg_temp.check(
  (select (fuel -> 'diesel' ->> 'price')::numeric = 3.799 and (fuel -> 'regular' ->> 'price')::numeric = 3.099
          and fuel -> 'diesel' ? 'at'
     from locations where id = '11111111-0000-0000-0000-000000000001'),
  'latest price per grade with timestamp');

-- F5/F6 editorial rule: any signed-in user can update amenity values, nothing else.
select set_amenities('11111111-0000-0000-0000-000000000001',
  '{"showers":"yes","rv_dump":"yes","dump_fee":"paid","dump_fee_amount":"5","potable_water":"no"}');
select pg_temp.check(
  (select showers = 'yes' and rv_dump = 'yes' and dump_fee = 'paid' and dump_fee_amount = 5 and potable_water = 'no'
     from locations where id = '11111111-0000-0000-0000-000000000001'),
  'amenities and RV fields updated through set_amenities');
do $$ begin
  perform set_amenities('11111111-0000-0000-0000-000000000001', '{"rating_count":"500"}');
  raise exception 'FAIL: edited a protected field';
exception when invalid_parameter_value then raise notice 'ok  protected fields rejected';
end $$;

-- F2.5: stops along a route, ordered by distance along it, not straight-line.
reset role;
insert into locations (id, name, stop_type, geog, access) values
  ('22222222-0000-0000-0000-000000000001', 'Far north, on route', 'gas_station', 'SRID=4326;POINT(-84.391 34.90)', 'customers'),
  ('22222222-0000-0000-0000-000000000002', 'Just ahead, on route', 'truck_stop', 'SRID=4326;POINT(-84.389 34.20)', 'free'),
  ('22222222-0000-0000-0000-000000000003', 'Off the corridor', 'park', 'SRID=4326;POINT(-84.20 34.50)', 'free');
select pg_temp.act('anon');
select pg_temp.check(
  (select array_agg(id order by along_m) = array[
      '11111111-0000-0000-0000-000000000001'::uuid, '22222222-0000-0000-0000-000000000002', '22222222-0000-0000-0000-000000000001']
     from stops_along_route('{"type":"LineString","coordinates":[[-84.39,33.75],[-84.39,35.0]]}', 1600)),
  'route results ordered along the route, off-corridor stop excluded');
select pg_temp.check(
  (select abs(along_m - 27750) < 300 and off_route_m < 1
     from stops_along_route('{"type":"LineString","coordinates":[[-84.39,33.75],[-84.39,35.0]]}', 1600)
    where id = '11111111-0000-0000-0000-000000000001'),
  'distance along route in metres (~27.7 km)');
select pg_temp.check(
  (select array_agg(id order by distance_m) = array[
      '22222222-0000-0000-0000-000000000002'::uuid, '11111111-0000-0000-0000-000000000001']
     from stops_near(34.15, -84.39, 25000)),
  'nearby stops ordered by distance');

-- F7.3 / F7.4: three users flag a location, it is hidden; an admin restores it.
select pg_temp.act('a');
insert into flags (target_type, target_id, location_id, reason) values ('location', '22222222-0000-0000-0000-000000000003', '22222222-0000-0000-0000-000000000003', 'spam');
select pg_temp.act('b');
insert into flags (target_type, target_id, location_id, reason) values ('location', '22222222-0000-0000-0000-000000000003', '22222222-0000-0000-0000-000000000003', 'not real');
select pg_temp.check((select count(*) = 1 from locations where id = '22222222-0000-0000-0000-000000000003'), 'two flags: still visible');
select pg_temp.act('c');
insert into flags (target_type, target_id, location_id, reason) values ('location', '22222222-0000-0000-0000-000000000003', '22222222-0000-0000-0000-000000000003', 'fake');
select pg_temp.check((select count(*) = 0 from locations where id = '22222222-0000-0000-0000-000000000003'), 'three flags: hidden pending review');
select pg_temp.check((select count(*) = 1 from flags), 'users only see their own flags');
do $$ begin
  perform moderate_flag((select id from flags limit 1), 'restore');
  raise exception 'FAIL: non-admin moderated';
exception when insufficient_privilege then raise notice 'ok  only admins moderate';
end $$;
select pg_temp.act('d');
select pg_temp.check((select count(*) = 3 from flags), 'admin sees the moderation queue');
select moderate_flag((select id from flags limit 1), 'restore');
select pg_temp.check(
  (select moderation = 'visible' from locations where id = '22222222-0000-0000-0000-000000000003')
  and (select bool_and(status = 'actioned') from flags), 'admin restores; flags closed');

-- Rating removed by moderation drops out of the averages.
insert into flags (target_type, target_id, location_id, reason)
  select 'rating', id, location_id, 'abusive' from ratings where user_id = '00000000-0000-0000-0000-00000000000b';
select moderate_flag((select id from flags where target_type = 'rating'), 'remove');
select pg_temp.check(
  (select rating_count = 1 and avg_clean = 5 from locations where id = '11111111-0000-0000-0000-000000000001'),
  'removed rating leaves the averages');

-- Section 10: plan field defaults to free and users cannot upgrade themselves.
select pg_temp.act('a');
update profiles set plan = 'premium', is_admin = true, rig_length_ft = 32 where id = auth.uid();
select pg_temp.check(
  (select plan = 'free' and not is_admin and rig_length_ft = 32 from profiles where id = auth.uid()),
  'rig profile editable; plan and admin are not');

-- F7.2 favorites are private to their owner.
insert into favorites (location_id) values ('11111111-0000-0000-0000-000000000001');
select pg_temp.act('b');
select pg_temp.check((select count(*) = 0 from favorites), 'favorites are private');

reset role;
\echo ALL TESTS PASSED
