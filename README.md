# RestRoute demo

A working demo of a crowdsourced restroom and rest-area map, built against the
**RestRoute Feature Spec v1.2**. One React Native + Expo codebase (iOS, Android, web) on a
shared Supabase backend (Postgres + PostGIS, Auth, Storage, Realtime).

**Try it:** open the live link on your phone **and** your laptop. Rate a stop, report it closed, or
tap "I was here – still good" on one device: the other updates within a second or two, with no reload.
That is the spec's core requirement (section 1, and section 9 point 2).

> The stops are **sample data**. They sit on the real I-75, I-95, I-10 and I-40 road geometry, but
> the names, ratings and prices are invented for the demo.

## What the demo covers

| Spec | In the demo |
|---|---|
| F2.1 Map with pins | Clustered pins that split apart on zoom; tap for a summary card (name, type, rating, open now, distance) |
| F2.2 List view | Same results as the map; sort by nearest, top rated, or fuel price per grade |
| F2.3 Search | City (geocoded), highway ("I-75", "i75", "US 1"), stop name, or "Near me" (GPS) |
| F2.4 Filters | Open now, type, minimum rating, any F5/F6 amenity; combined with AND; one-tap clear |
| F2.5 Along my route | Driving route to a destination; stops within 1 mile, ordered by distance **along the route** (PostGIS `ST_LineLocatePoint`) |
| F3.1–F3.5 Tagging | Name and type, pin at GPS then drag to the exact spot, access (required), 24/7 or hours per day, photo to cloud storage |
| F4.1 / F4.2 Ratings | Four scores plus a review; one set per user per stop, editable; averages kept by the database |
| F4.3 Issue reports | Closed, out of order, no supplies, other. "Closed" hides the stop from default results until re-verified |
| F4.4 Last verified | "I was here – still good" refreshes the stamp and resolves open reports; over 90 days shows "may be outdated" |
| F5.1–F5.7, F6 | Every amenity is yes / no / unknown, editable by any signed-in user; RV dump fee, rinse hose, water fill and access notes |
| F5.6 Fuel prices | Per grade, timestamped; stale after 7 days; sort the list and route results by price |
| F7.1 Accounts | Browse without an account; contributing asks to sign in (guest accounts in the demo) |
| F7.2 Favorites | Saved per account, available on any device |
| F7.3 / F7.4 Moderation | Flag a stop, review or photo; three different users flagging a stop hides it; admin queue to keep, remove or restore |
| Section 10 | `plan` field (free/premium, default free) and rig profile fields on the user record; no billing or locks |

Not in the demo (they come with the full build): Apple, Google and email sign-in (same Supabase Auth),
App Store / Play Store builds, the production map provider.

## How it's built

```
app/                 Expo app (TypeScript)
  App.tsx            layout: side panel + map on desktop, map/list toggle on phones
  src/logic.ts       open-now with time zones, filters, sorting, freshness, route maths (unit tested)
  src/backend/       Supabase backend, plus a sample backend that runs without keys
  src/map/           MapLibre on web, react-native-maps on iOS / Android
  src/ui/            stop detail, add-a-stop flow, filters, route, account, moderation
supabase/
  migrations/        schema, triggers, security rules, route and nearby queries, storage
  tests/             28 behaviour tests run on a local Postgres + PostGIS
  seed.sql           the sample stops
scripts/make-seed.mjs  generates the sample stops along real highway geometry
```

The rules live in the database, not only in the app. Averages, open issues, latest fuel prices and
the "closed hides it" rule are kept by triggers. Row Level Security means anyone can read, but only
signed-in users can write, and only as themselves. A user cannot change server-owned fields such as
averages or the verified stamp, cannot edit someone else's rating, and cannot upgrade their own plan.

## Run it

```bash
cd app
npm install
npm run web          # or: npx expo start  (scan with Expo Go for iOS / Android)
npm test             # logic tests
```

`app/.env` holds the Supabase project URL and **anon** key. Both are public by design (every web
app ships them), and access is controlled by the Row Level Security rules. Remove the file and the app runs
on built-in sample data instead.

Database: run `supabase/setup_all.sql` in the Supabase SQL Editor (or `supabase db push` plus the
seed), then enable anonymous sign-ins. Database tests: `PSQL=psql supabase/tests/run.sh` against
a local Postgres with PostGIS.

Deploy: `vercel.json` builds the web app (`expo export --platform web`) on every push.
