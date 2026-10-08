# RestRoute demo

A small working demo of a crowdsourced restroom and rest-area map, built against the
RestRoute Feature Spec v1.2: React Native + Expo (iOS, Android and web), Supabase
(Postgres + PostGIS, Auth, Storage, Realtime).

**Status:** in progress. The first working version, with a live web link, lands here within 24 hours.

What it will show:

- Map with clustered pins and a list sorted by distance (F2.1, F2.2)
- Add a stop with a drag-to-place pin, access and hours (F3.1 to F3.4)
- Four quick ratings, one set per user, averages kept by the database (F4.1)
- "I was here, still good" and "Report closed" (F4.3, F4.4)
- Two devices seeing the same pins and ratings live (shared database requirement)
- The "along my route" query in PostGIS, with tests (F2.5)
