// Pure rules shared by every screen: open-now, distances, freshness, filters, sorting, route maths.
import { PRICE_STALE_DAYS, STALE_DAYS } from './meta';
import type { AmenityKey, Day, Grade, Hours, LngLat, RouteHit, Stop, StopType } from './types';

const DAY_KEYS: Day[] = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const WEEKDAY: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

const toMin = (hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
};

// Day of week and minutes since midnight at the stop, in the stop's own time zone.
export function localClock(tz: string, now: Date): { day: number; min: number } {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '0';
  return { day: WEEKDAY[get('weekday')], min: (Number(get('hour')) % 24) * 60 + Number(get('minute')) };
}

export type OpenState = { open: boolean; label: string };

// F3.4: 24/7 or custom hours per day. Intervals past midnight (22:00-02:00) carry into the next day.
export function openState(stop: Pick<Stop, 'open_24h' | 'hours' | 'tz'>, now = new Date()): OpenState {
  if (stop.open_24h) return { open: true, label: 'Open 24/7' };
  const hours: Hours = stop.hours ?? {};
  if (!Object.keys(hours).length) return { open: false, label: 'Hours unknown' };
  const { day, min } = localClock(stop.tz, now);
  const today = hours[DAY_KEYS[day]] ?? [];
  for (const [o, c] of today) {
    const a = toMin(o), b = toMin(c);
    if (b > a ? min >= a && min < b : min >= a) return { open: true, label: `Open until ${c}` };
  }
  const yesterday = hours[DAY_KEYS[(day + 6) % 7]] ?? [];
  for (const [o, c] of yesterday) {
    const a = toMin(o), b = toMin(c);
    if (b <= a && min < b) return { open: true, label: `Open until ${c}` };
  }
  const later = today.map(([o]) => o).filter((o) => toMin(o) > min).sort()[0];
  return { open: false, label: later ? `Closed · opens ${later}` : 'Closed now' };
}

export function hoursText(hours: Hours | null): { day: Day; text: string }[] {
  const order: Day[] = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  return order.map((d) => ({
    day: d,
    text: hours?.[d]?.length ? hours[d]!.map(([o, c]) => `${o}–${c}`).join(', ') : 'Closed',
  }));
}

export function distanceM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const R = 6371008.8, r = Math.PI / 180;
  const dLat = (b.lat - a.lat) * r, dLng = (b.lng - a.lng) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

export const miles = (m: number) => {
  const mi = m / 1609.344;
  return mi < 0.1 ? 'here' : mi < 10 ? `${mi.toFixed(1)} mi` : `${Math.round(mi)} mi`;
};

export const daysSince = (iso: string, now = new Date()) => (now.getTime() - Date.parse(iso)) / 86400000;

// F4.4
export const isOutdated = (stop: Pick<Stop, 'last_verified_at'>, now = new Date()) =>
  daysSince(stop.last_verified_at, now) > STALE_DAYS;
// F5.6
export const isPriceStale = (at: string, now = new Date()) => daysSince(at, now) > PRICE_STALE_DAYS;

export function ago(iso: string, now = new Date()): string {
  const d = daysSince(iso, now);
  if (d < 1 / 24) return 'just now';
  if (d < 1) return `${Math.floor(d * 24)} h ago`;
  if (d < 2) return 'yesterday';
  if (d < 60) return `${Math.floor(d)} days ago`;
  return `${Math.floor(d / 30)} months ago`;
}

// F4.3: a stop reported closed is left out of default results until someone verifies it.
export const isReportedClosed = (s: Pick<Stop, 'open_issues'>) => s.open_issues.includes('closed');

export type Filters = {
  openNow: boolean;
  types: StopType[];
  minRating: number;            // 0 = any
  amenities: AmenityKey[];      // all must be "yes"
  includeClosed: boolean;
};
export const NO_FILTERS: Filters = { openNow: false, types: [], minRating: 0, amenities: [], includeClosed: false };
export const activeFilterCount = (f: Filters) =>
  (f.openNow ? 1 : 0) + f.types.length + (f.minRating ? 1 : 0) + f.amenities.length + (f.includeClosed ? 1 : 0);

// F2.4: filters combine with AND, and apply identically to map, list and route results.
export function applyFilters(stops: Stop[], f: Filters, now = new Date()): Stop[] {
  return stops.filter((s) => {
    if (!f.includeClosed && isReportedClosed(s)) return false;
    if (f.types.length && !f.types.includes(s.stop_type)) return false;
    if (f.minRating && (s.avg_overall ?? 0) < f.minRating) return false;
    for (const a of f.amenities) if (s[a] !== 'yes') return false;
    if (f.openNow && !openState(s, now).open) return false;
    return true;
  });
}

export type SortKey = 'nearest' | 'rating' | `price:${Grade}`;

export function sortStops(stops: Stop[], key: SortKey, distanceOf: (s: Stop) => number): Stop[] {
  const out = [...stops];
  if (key === 'nearest') return out.sort((a, b) => distanceOf(a) - distanceOf(b));
  if (key === 'rating') {
    return out.sort((a, b) => (b.avg_overall ?? -1) - (a.avg_overall ?? -1) || b.rating_count - a.rating_count);
  }
  const grade = key.slice(6) as Grade;
  // Stops without a price for that grade go last.
  return out.sort((a, b) => (a.fuel[grade]?.price ?? Infinity) - (b.fuel[grade]?.price ?? Infinity) || distanceOf(a) - distanceOf(b));
}

// F2.3: "I-75", "i75", "I 75", "US 1", "interstate 10" -> normalised highway names.
export function parseHighway(q: string): string | null {
  const m = q.trim().match(/^(i|interstate|us|sr|hwy|highway|route)[\s-]*(\d{1,3})\s*([nsew]b?)?$/i);
  if (!m) return null;
  const p = m[1].toLowerCase();
  const prefix = p === 'i' || p === 'interstate' ? 'I' : p === 'us' ? 'US' : 'SR';
  return `${prefix}-${m[2]}`;
}

export function textMatch(stop: Stop, q: string): boolean {
  const t = q.trim().toLowerCase();
  if (!t) return true;
  return [stop.name, stop.city, stop.state, stop.highway].some((v) => v?.toLowerCase().includes(t));
}

// ---------------------------------------------------------------- route maths (sample mode; the database does this in PostGIS)

const M_PER_DEG = 111320;

// Distance along the line to the closest point, and how far off the line the point is.
export function locateOnLine(line: LngLat[], p: { lat: number; lng: number }): { along: number; off: number } {
  let best = { along: 0, off: Infinity };
  let walked = 0;
  for (let i = 1; i < line.length; i++) {
    const [ax, ay] = line[i - 1], [bx, by] = line[i];
    const k = Math.cos((ay * Math.PI) / 180) * M_PER_DEG;
    const vx = (bx - ax) * k, vy = (by - ay) * M_PER_DEG;
    const wx = (p.lng - ax) * k, wy = (p.lat - ay) * M_PER_DEG;
    const len2 = vx * vx + vy * vy;
    const t = len2 ? Math.max(0, Math.min(1, (wx * vx + wy * vy) / len2)) : 0;
    const dx = wx - t * vx, dy = wy - t * vy;
    const off = Math.hypot(dx, dy);
    const seg = Math.sqrt(len2);
    if (off < best.off) best = { along: walked + t * seg, off };
    walked += seg;
  }
  return best;
}

export function stopsAlongLine(stops: Stop[], line: LngLat[], corridorM: number): RouteHit[] {
  return stops
    .map((s) => {
      const { along, off } = locateOnLine(line, s);
      return { id: s.id, along_m: along, off_route_m: off };
    })
    .filter((h) => h.off_route_m <= corridorM)
    .sort((a, b) => a.along_m - b.along_m);
}

// Keeps a long route light enough to send to the database: Douglas-Peucker in metres.
export function simplifyLine(line: LngLat[], toleranceM = 60): LngLat[] {
  if (line.length < 3) return line;
  const keep = new Uint8Array(line.length);
  keep[0] = keep[line.length - 1] = 1;
  const stack: [number, number][] = [[0, line.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop()!;
    let maxD = 0, idx = -1;
    for (let i = s + 1; i < e; i++) {
      const d = locateOnLine([line[s], line[e]], { lng: line[i][0], lat: line[i][1] }).off;
      if (d > maxD) { maxD = d; idx = i; }
    }
    if (maxD > toleranceM && idx > 0) {
      keep[idx] = 1;
      stack.push([s, idx], [idx, e]);
    }
  }
  return line.filter((_, i) => keep[i]);
}

// US pump style: 3.099 -> $3.09⁹
export const fmtPrice = (p: number) => {
  const s = p.toFixed(3);
  return s.endsWith('9') ? `$${s.slice(0, -1)}⁹` : `$${p.toFixed(2)}`;
};
export const fmtScore = (v: number | null) => (v == null ? '–' : v.toFixed(1));
