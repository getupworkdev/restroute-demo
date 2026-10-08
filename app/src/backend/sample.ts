// Sample mode: runs without a backend, on the bundled sample stops. Changes stay on this
// device only, so it is for trying the screens; the shared Supabase backend is the real app.
import { stopsAlongLine } from '../logic';
import type { AmenityKey, Detail, Flag, Grade, Issue, NewStop, Rating, Report, Session, Stop, Tri } from '../types';
import { SignInRequired, type Backend, type PhotoInput } from './types';
import sample from '../data/sample.json';

type Raw = typeof sample;
const id = () => Math.random().toString(16).slice(2) + Date.now().toString(16);
const now = () => new Date().toISOString();
const avg = (xs: number[]) => (xs.length ? Math.round((xs.reduce((a, b) => a + b, 0) / xs.length) * 100) / 100 : null);

export class SampleBackend implements Backend {
  readonly mode = 'sample' as const;
  private stops = new Map<string, Stop>();
  private ratings: Rating[] = [];
  private reports: Report[] = [];
  private prices: { location_id: string; grade: Grade; price: number; reported_at: string }[] = [];
  private photos: { id: string; location_id: string; url: string; created_at: string }[] = [];
  private favs = new Set<string>();
  private flags: Flag[] = [];
  private current: Session | null = null;
  private sessionCbs = new Set<(s: Session | null) => void>();
  private stopCbs = new Set<(s: Stop) => void>();
  private detailCbs = new Map<string, Set<() => void>>();

  constructor() {
    const raw = sample as Raw;
    const names = Object.fromEntries(raw.users.map((u) => [u.id, u.name]));
    for (const l of raw.locations) {
      this.stops.set(l.id, {
        ...(l as unknown as Stop), avg_clean: null, avg_safety: null, avg_supplies: null, avg_overall: null,
        rating_count: 0, open_issues: [], fuel: {}, photo_count: 0,
      });
    }
    this.ratings = raw.ratings.map((r) => ({ ...r, id: id(), author: names[r.user_id] ?? 'Traveler', updated_at: r.created_at }));
    this.reports = raw.reports.map((r) => ({ ...r, id: id(), issue: r.issue as Issue, status: 'open' as const }));
    this.prices = raw.prices.map((p) => ({ ...p, grade: p.grade as Grade }))
      .sort((a, b) => a.reported_at.localeCompare(b.reported_at));
    for (const s of this.stops.values()) this.recompute(s.id, false);
  }

  private recompute(locationId: string, notify = true) {
    const s = this.stops.get(locationId);
    if (!s) return;
    const rs = this.ratings.filter((r) => r.location_id === locationId);
    const fuel: Stop['fuel'] = {};
    for (const p of this.prices.filter((p) => p.location_id === locationId)) fuel[p.grade] = { price: p.price, at: p.reported_at };
    const next: Stop = {
      ...s,
      avg_clean: avg(rs.map((r) => r.clean)), avg_safety: avg(rs.map((r) => r.safety)),
      avg_supplies: avg(rs.map((r) => r.supplies)), avg_overall: avg(rs.map((r) => r.overall)),
      rating_count: rs.length,
      open_issues: [...new Set(this.reports.filter((r) => r.location_id === locationId && r.status === 'open').map((r) => r.issue))].sort(),
      fuel,
      photo_count: this.photos.filter((p) => p.location_id === locationId).length,
    };
    this.stops.set(locationId, next);
    if (notify) {
      this.stopCbs.forEach((cb) => cb(next));
      this.detailCbs.get(locationId)?.forEach((cb) => cb());
    }
  }

  private uid() {
    if (!this.current) throw new SignInRequired();
    return this.current.userId;
  }

  session() { return this.current; }
  onSession(cb: (s: Session | null) => void) { this.sessionCbs.add(cb); return () => void this.sessionCbs.delete(cb); }
  async signInGuest(displayName: string) {
    this.current = { userId: id(), displayName: displayName.trim() || 'Traveler', isAdmin: true };
    this.sessionCbs.forEach((cb) => cb(this.current));
  }
  async signOut() { this.current = null; this.sessionCbs.forEach((cb) => cb(null)); }

  async loadStops() { return [...this.stops.values()]; }
  async getStop(sid: string) { return this.stops.get(sid) ?? null; }
  onStopChanged(cb: (s: Stop) => void) { this.stopCbs.add(cb); return () => void this.stopCbs.delete(cb); }

  async getDetail(sid: string): Promise<Detail> {
    const ratings = this.ratings.filter((r) => r.location_id === sid).sort((a, b) => b.created_at.localeCompare(a.created_at));
    return {
      ratings,
      reports: this.reports.filter((r) => r.location_id === sid && r.status === 'open'),
      photos: this.photos.filter((p) => p.location_id === sid),
      priceHistory: this.prices.filter((p) => p.location_id === sid).reverse(),
      myRating: this.current ? ratings.find((r) => r.user_id === this.current!.userId) ?? null : null,
      favorite: this.favs.has(sid),
    };
  }
  onDetailChanged(sid: string, cb: () => void) {
    if (!this.detailCbs.has(sid)) this.detailCbs.set(sid, new Set());
    this.detailCbs.get(sid)!.add(cb);
    return () => void this.detailCbs.get(sid)?.delete(cb);
  }

  async addStop(input: NewStop, photo: PhotoInput | null) {
    const created_by = this.uid();
    const base = Object.fromEntries(
      ['gas', 'diesel', 'fast_food', 'diner', 'convenience_store', 'vending', 'coffee', 'car_parking', 'truck_parking',
        'rv_parking', 'overnight_parking', 'showers', 'laundry', 'rv_dump', 'rinse_hose', 'potable_water', 'wheelchair',
        'baby_changing', 'family_restroom', 'pet_area', 'bottle_refill', 'wifi', 'ev_charging', 'picnic', 'atm']
        .map((k) => [k, 'unknown']));
    const { amenities, ...rest } = input;
    const stop = {
      ...base, ...amenities, ...rest, id: id(), highway: input.highway.trim().toUpperCase() || null, city: null, state: null,
      dump_fee: null, dump_fee_amount: null, potable_note: null, rv_note: null, avg_clean: null, avg_safety: null,
      avg_supplies: null, avg_overall: null, rating_count: 0, open_issues: [], fuel: {}, photo_count: 0,
      last_verified_at: now(), created_at: now(), created_by,
    } as Stop;
    this.stops.set(stop.id, stop);
    if (photo) await this.addPhoto(stop.id, photo);
    this.recompute(stop.id);
    return this.stops.get(stop.id)!;
  }

  async rate(locationId: string, scores: { clean: number; safety: number; supplies: number; overall: number }, review: string) {
    const uid = this.uid();
    const mine = this.ratings.find((r) => r.location_id === locationId && r.user_id === uid);
    if (mine) Object.assign(mine, scores, { review: review.trim() || null, updated_at: now() });
    else this.ratings.push({ id: id(), location_id: locationId, user_id: uid, author: this.current!.displayName, ...scores,
      review: review.trim() || null, created_at: now(), updated_at: now() });
    this.recompute(locationId);
  }

  async report(locationId: string, issue: Issue, note: string) {
    this.reports.push({ id: id(), location_id: locationId, user_id: this.uid(), issue, note: note.trim() || null, status: 'open', created_at: now() });
    this.recompute(locationId);
  }

  async verify(locationId: string) {
    this.uid();
    this.reports.filter((r) => r.location_id === locationId).forEach((r) => { r.status = 'resolved'; });
    const s = this.stops.get(locationId);
    if (s) this.stops.set(locationId, { ...s, last_verified_at: now() });
    this.recompute(locationId);
  }

  async addPrice(locationId: string, grade: Grade, price: number) {
    this.uid();
    this.prices.push({ location_id: locationId, grade, price, reported_at: now() });
    this.recompute(locationId);
  }

  async setAmenities(locationId: string, values: Partial<Record<AmenityKey, Tri>> & Record<string, string>) {
    this.uid();
    const s = this.stops.get(locationId);
    if (s) this.stops.set(locationId, { ...s, ...values } as Stop);
    this.recompute(locationId);
  }

  async addPhoto(locationId: string, photo: PhotoInput) {
    this.uid();
    this.photos.unshift({ id: id(), location_id: locationId, url: photo.uri, created_at: now() });
    this.recompute(locationId);
  }

  async setFavorite(locationId: string, on: boolean) {
    this.uid();
    if (on) this.favs.add(locationId); else this.favs.delete(locationId);
    this.detailCbs.get(locationId)?.forEach((cb) => cb());
  }
  async favorites() { return [...this.favs]; }

  async flag(target: { type: 'location' | 'rating' | 'photo'; id: string; locationId: string }, reason: string) {
    this.uid();
    this.flags.push({ id: id(), target_type: target.type, target_id: target.id, location_id: target.locationId,
      location_name: this.stops.get(target.locationId)?.name ?? null, reason, status: 'pending', created_at: now() });
  }

  async stopsAlongRoute(line: [number, number][], corridorM: number) {
    return stopsAlongLine([...this.stops.values()], line, corridorM);
  }

  async moderationQueue() { return this.flags.filter((f) => f.status === 'pending'); }
  async moderate(flagId: string, action: 'dismiss' | 'remove' | 'restore') {
    const f = this.flags.find((x) => x.id === flagId);
    if (!f) return;
    f.status = action === 'dismiss' ? 'dismissed' : 'actioned';
    if (action === 'remove' && f.target_type === 'location') {
      this.stops.delete(f.target_id);
      this.stopCbs.forEach((cb) => cb({ id: f.target_id, removed: true } as unknown as Stop));
    }
  }
}
