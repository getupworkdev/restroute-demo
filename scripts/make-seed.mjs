// Generates the sample stops used by the demo, along four real highway corridors.
// Positions follow the actual road geometry (scripts/routes/*.json, from OSRM);
// names, amenities, ratings and prices are invented sample data and labelled as such.
//
// Writes:
//   supabase/seed.sql          -> loaded into Supabase
//   app/src/data/sample.json   -> used by the app when no Supabase keys are set
//
// Usage: node scripts/make-seed.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

let seed = 20261008;
function rand() {
  seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (a) => a[Math.floor(rand() * a.length)];
const chance = (p) => rand() < p;
const between = (lo, hi) => lo + rand() * (hi - lo);
function uuid() {
  const h = [...Array(32)].map(() => Math.floor(rand() * 16).toString(16)).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

const NOW = Date.parse('2026-10-08T12:00:00Z');
const daysAgo = (d) => new Date(NOW - d * 86400000).toISOString();

const corridors = [
  { file: 'i75', highway: 'I-75', tz: 'America/New_York', count: 18, region: 'GA / TN' },
  { file: 'i95', highway: 'I-95', tz: 'America/New_York', count: 12, region: 'FL / GA' },
  { file: 'i10', highway: 'I-10', tz: 'America/Chicago', count: 14, region: 'TX' },
  { file: 'i40', highway: 'I-40', tz: 'America/Phoenix', count: 12, region: 'AZ' },
];

const TYPES = [
  ['rest_area', 0.24], ['gas_station', 0.24], ['truck_stop', 0.18], ['fast_food', 0.12],
  ['store', 0.08], ['park', 0.07], ['public_restroom', 0.07],
];
const LABEL = {
  rest_area: 'Rest Area', gas_station: 'Gas Station', truck_stop: 'Truck Stop', fast_food: 'Fast Food',
  store: 'Store', park: 'Park', public_restroom: 'Public Restroom',
};
function pickType() {
  let r = rand();
  for (const [t, w] of TYPES) { if ((r -= w) < 0) return t; }
  return 'rest_area';
}

const R = 6371008.8;
function hav([lng1, lat1], [lng2, lat2]) {
  const toR = Math.PI / 180;
  const dLat = (lat2 - lat1) * toR, dLng = (lng2 - lng1) * toR;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * toR) * Math.cos(lat2 * toR) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}
function pointAt(coords, cum, d) {
  let i = cum.findIndex((c) => c >= d);
  if (i <= 0) i = 1;
  const seg = cum[i] - cum[i - 1] || 1;
  const f = (d - cum[i - 1]) / seg;
  const [a, b] = [coords[i - 1], coords[i]];
  const p = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
  // Step off the carriageway, perpendicular to the road, like an exit or service plaza.
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const len = Math.hypot(dx, dy) || 1;
  const off = between(90, 260) * (chance(0.5) ? 1 : -1);
  const mLat = 111320, mLng = 111320 * Math.cos((p[1] * Math.PI) / 180);
  return [+(p[0] + (-dy / len) * off / mLng).toFixed(6), +(p[1] + (dx / len) * off / mLat).toFixed(6)];
}

const tri = (pYes, pNo = 0.15) => { const r = rand(); return r < pYes ? 'yes' : r < pYes + pNo ? 'no' : 'unknown'; };
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const allDays = (open, close) => Object.fromEntries(DAYS.map((d) => [d, [[open, close]]]));

function amenitiesFor(type) {
  const fuelStop = type === 'gas_station' || type === 'truck_stop';
  const a = {
    gas: fuelStop ? 'yes' : type === 'rest_area' ? 'no' : tri(0.1, 0.5),
    diesel: type === 'truck_stop' ? 'yes' : type === 'gas_station' ? tri(0.55, 0.3) : 'no',
    fast_food: type === 'fast_food' ? 'yes' : type === 'truck_stop' ? tri(0.8) : tri(0.25),
    diner: type === 'truck_stop' ? tri(0.4) : tri(0.05),
    convenience_store: fuelStop ? 'yes' : type === 'store' ? 'yes' : tri(0.1),
    vending: type === 'rest_area' ? tri(0.85) : tri(0.3),
    coffee: fuelStop || type === 'fast_food' ? tri(0.85) : tri(0.15),
    car_parking: 'yes',
    truck_parking: type === 'truck_stop' ? 'yes' : type === 'rest_area' ? tri(0.75) : tri(0.1, 0.5),
    rv_parking: type === 'truck_stop' || type === 'rest_area' ? tri(0.65) : tri(0.15, 0.4),
    overnight_parking: type === 'truck_stop' ? 'yes' : type === 'rest_area' ? tri(0.35, 0.35) : tri(0.05, 0.5),
    showers: type === 'truck_stop' ? tri(0.9) : tri(0.03, 0.6),
    laundry: type === 'truck_stop' ? tri(0.6) : 'unknown',
    rv_dump: type === 'truck_stop' || type === 'rest_area' ? tri(0.3, 0.4) : tri(0.03, 0.4),
    rinse_hose: 'unknown',
    potable_water: type === 'rest_area' || type === 'truck_stop' ? tri(0.4, 0.25) : 'unknown',
    wheelchair: tri(0.7),
    baby_changing: tri(0.55),
    family_restroom: type === 'rest_area' || type === 'truck_stop' ? tri(0.5) : tri(0.2),
    pet_area: type === 'rest_area' ? tri(0.85) : type === 'truck_stop' ? tri(0.5) : tri(0.1),
    bottle_refill: tri(0.3),
    wifi: type === 'rest_area' ? tri(0.5) : tri(0.4),
    ev_charging: fuelStop ? tri(0.3, 0.5) : tri(0.1, 0.5),
    picnic: type === 'rest_area' || type === 'park' ? tri(0.85) : tri(0.05, 0.5),
    atm: fuelStop || type === 'store' ? tri(0.75) : tri(0.05, 0.5),
  };
  const extra = {};
  if (a.rv_dump === 'yes') {
    extra.dump_fee = chance(0.5) ? 'free' : 'paid';
    if (extra.dump_fee === 'paid') extra.dump_fee_amount = pick([5, 7.5, 10]);
    a.rinse_hose = tri(0.6);
    extra.rv_note = pick(['Pull-through lane, fits 40 ft rigs', 'Tight turn on entry, under 35 ft recommended', 'Behind the diesel island']);
  }
  if (a.potable_water === 'yes') extra.potable_note = pick(['Threaded spigot by the dump station', 'Hose bib on the north side of the building']);
  return { ...a, ...extra };
}

function hoursFor(type) {
  if (type === 'rest_area' || type === 'truck_stop') return { open_24h: true, hours: null };
  if (type === 'gas_station') return chance(0.6) ? { open_24h: true, hours: null } : { open_24h: false, hours: allDays('05:00', '23:00') };
  if (type === 'fast_food') return { open_24h: false, hours: allDays('06:00', '23:00') };
  if (type === 'store') return { open_24h: false, hours: allDays('07:00', '22:00') };
  if (type === 'park') return { open_24h: false, hours: allDays('07:00', '19:30') };
  const h = allDays('06:00', '20:00');
  h.sun = [['08:00', '18:00']];
  return { open_24h: false, hours: h };
}

const REVIEWS = {
  good: ['Spotless and well lit at night.', 'Clean, stocked, easy in and out.', 'Staff keeps it tidy. Plenty of parking.',
    'Best stop on this stretch.', 'Family restroom was clean, changing table worked.', 'Safe feeling at 2am, lots of lights.'],
  mid: ['Fine for a quick stop.', 'Okay, could use more paper towels.', 'Busy at lunch, restrooms so-so.',
    'Decent but the hand dryer was broken.'],
  bad: ['Out of soap and paper.', 'Dark lot, would not stop at night.', 'Needs cleaning badly.'],
};

const users = Array.from({ length: 8 }, (_, i) => ({ id: uuid(), name: ['Dana', 'Luis', 'Priya', 'Mike', 'Tasha', 'Ray', 'Jen', 'Omar'][i] }));

const locations = [], ratings = [], reports = [], prices = [];
const counters = {};
for (const c of corridors) {
  const { coordinates: coords } = JSON.parse(readFileSync(join(root, 'scripts/routes', `${c.file}.json`), 'utf8'));
  const cum = [0];
  for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + hav(coords[i - 1], coords[i]));
  const total = cum.at(-1);
  for (let k = 0; k < c.count; k++) {
    const d = ((k + 0.5) / c.count) * total + between(-0.3, 0.3) * (total / c.count);
    const [lng, lat] = pointAt(coords, cum, Math.max(1000, Math.min(total - 1000, d)));
    const type = pickType();
    counters[`${c.highway}-${type}`] = (counters[`${c.highway}-${type}`] || 0) + 1;
    const id = uuid();
    const createdDays = Math.floor(between(120, 400));
    // Most stops verified recently; some deliberately stale to show the "may be outdated" notice.
    const verifiedDays = chance(0.18) ? Math.floor(between(95, 260)) : Math.floor(between(0, 45));
    const loc = {
      id, name: `Sample ${LABEL[type]} ${counters[`${c.highway}-${type}`]} · ${c.highway}`,
      stop_type: type, lat, lng, highway: c.highway, city: null, state: c.region,
      access: type === 'rest_area' || type === 'park' || type === 'public_restroom' ? 'free'
        : type === 'store' || type === 'fast_food' ? pick(['customers', 'customers', 'code']) : pick(['free', 'customers']),
      ...hoursFor(type), tz: c.tz, ...amenitiesFor(type),
      created_by: pick(users).id, created_at: daysAgo(createdDays), last_verified_at: daysAgo(verifiedDays),
    };
    locations.push(loc);

    const quality = rand();
    const n = Math.floor(between(0, 7));
    const raters = [...users].sort(() => rand() - 0.5).slice(0, n);
    for (const u of raters) {
      const base = quality > 0.7 ? 4.4 : quality > 0.25 ? 3.4 : 2.2;
      const s = () => Math.max(1, Math.min(5, Math.round(base + between(-1, 1))));
      const overall = s();
      const r = { location_id: id, user_id: u.id, clean: s(), safety: s(), supplies: s(), overall,
        review: chance(0.6) ? pick(overall >= 4 ? REVIEWS.good : overall >= 3 ? REVIEWS.mid : REVIEWS.bad) : null,
        created_at: daysAgo(Math.floor(between(1, Math.min(createdDays, 200)))) };
      ratings.push(r);
    }

    if (loc.gas === 'yes' || loc.diesel === 'yes') {
      const regional = { 'I-75': 3.05, 'I-95': 3.15, 'I-10': 2.79, 'I-40': 3.49 }[c.highway];
      const age = chance(0.2) ? between(9, 30) : between(0.05, 5); // some stale prices (> 7 days)
      const at = daysAgo(age);
      const reg = +(regional + between(-0.18, 0.22)).toFixed(2) + 0.009;
      if (loc.gas === 'yes') {
        prices.push({ location_id: id, grade: 'regular', price: +reg.toFixed(3), reported_by: pick(users).id, reported_at: at });
        prices.push({ location_id: id, grade: 'midgrade', price: +(reg + 0.45).toFixed(3), reported_by: pick(users).id, reported_at: at });
        prices.push({ location_id: id, grade: 'premium', price: +(reg + 0.85).toFixed(3), reported_by: pick(users).id, reported_at: at });
      }
      if (loc.diesel === 'yes') {
        prices.push({ location_id: id, grade: 'diesel', price: +(reg + 0.62 + between(-0.1, 0.1)).toFixed(3), reported_by: pick(users).id, reported_at: at });
      }
    }
  }
}

// A few open issue reports so the freshness rules are visible straight away.
const reportable = locations.filter((l) => l.stop_type !== 'truck_stop');
reports.push({ location_id: reportable[3].id, user_id: users[1].id, issue: 'no_supplies', note: 'No toilet paper in the men\'s room', created_at: daysAgo(1) });
reports.push({ location_id: reportable[11].id, user_id: users[4].id, issue: 'out_of_order', note: 'Two of three stalls out of order', created_at: daysAgo(2) });
reports.push({ location_id: reportable[20].id, user_id: users[6].id, issue: 'closed', note: 'Closed for renovation, fenced off', created_at: daysAgo(3) });

// ---------------------------------------------------------------- outputs

mkdirSync(join(root, 'app/src/data'), { recursive: true });
writeFileSync(join(root, 'app/src/data/sample.json'),
  JSON.stringify({ generated: new Date(NOW).toISOString(), users, locations, ratings, reports, prices }));

const q = (v) => v === null || v === undefined ? 'null'
  : typeof v === 'number' ? String(v)
  : typeof v === 'boolean' ? String(v)
  : typeof v === 'object' ? `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`
  : `'${String(v).replace(/'/g, "''")}'`;

const LOC_COLS = ['id', 'name', 'stop_type', 'highway', 'city', 'state', 'access', 'open_24h', 'hours', 'tz',
  'gas', 'diesel', 'fast_food', 'diner', 'convenience_store', 'vending', 'coffee', 'car_parking', 'truck_parking',
  'rv_parking', 'overnight_parking', 'showers', 'laundry', 'rv_dump', 'dump_fee', 'dump_fee_amount', 'rinse_hose',
  'potable_water', 'potable_note', 'rv_note', 'wheelchair', 'baby_changing', 'family_restroom', 'pet_area',
  'bottle_refill', 'wifi', 'ev_charging', 'picnic', 'atm', 'created_by', 'created_at', 'last_verified_at'];

let sql = `-- Sample data for the RestRoute demo (generated by scripts/make-seed.mjs).
-- Stops sit on real highway geometry; names, ratings and prices are invented samples.
-- Safe to re-run: removes the previous sample data first.
begin;
delete from auth.users where raw_user_meta_data ->> 'sample' = 'true';
delete from public.locations where name like 'Sample %';

insert into auth.users (instance_id, id, aud, role, raw_user_meta_data, raw_app_meta_data, is_anonymous, created_at, updated_at) values
${users.map((u) => `  ('00000000-0000-0000-0000-000000000000', ${q(u.id)}, 'authenticated', 'authenticated', ${q({ display_name: u.name, sample: 'true' })}, '{}'::jsonb, true, now(), now())`).join(',\n')};

insert into public.locations (geog, ${LOC_COLS.join(', ')}) values
${locations.map((l) => `  ('SRID=4326;POINT(${l.lng} ${l.lat})', ${LOC_COLS.map((k) => q(l[k] ?? null)).join(', ')})`).join(',\n')};

insert into public.ratings (location_id, user_id, clean, safety, supplies, overall, review, created_at, updated_at) values
${ratings.map((r) => `  (${q(r.location_id)}, ${q(r.user_id)}, ${r.clean}, ${r.safety}, ${r.supplies}, ${r.overall}, ${q(r.review)}, ${q(r.created_at)}, ${q(r.created_at)})`).join(',\n')};

insert into public.fuel_prices (location_id, grade, price, reported_by, reported_at) values
${prices.map((p) => `  (${q(p.location_id)}, ${q(p.grade)}, ${p.price}, ${q(p.reported_by)}, ${q(p.reported_at)})`).join(',\n')};

insert into public.reports (location_id, user_id, issue, note, created_at) values
${reports.map((r) => `  (${q(r.location_id)}, ${q(r.user_id)}, ${q(r.issue)}, ${q(r.note)}, ${q(r.created_at)})`).join(',\n')};

-- The last-verified stamps above are part of the sample; keep them after the triggers ran.
${locations.map((l) => `update public.locations set last_verified_at = ${q(l.last_verified_at)} where id = ${q(l.id)};`).join('\n')}
commit;
`;
writeFileSync(join(root, 'supabase/seed.sql'), sql);
console.log(`${locations.length} stops, ${ratings.length} ratings, ${prices.length} prices, ${reports.length} reports`);
