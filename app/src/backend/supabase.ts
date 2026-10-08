// Shared backend: Supabase Postgres + PostGIS, Auth, Storage and Realtime.
// Every device talks to the same database, so a pin or rating added on one phone shows on all.
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { Platform } from 'react-native';
import 'react-native-url-polyfill/auto';
import { simplifyLine } from '../logic';
import type { Detail, Flag, NewStop, Rating, Session, Stop } from '../types';
import { SignInRequired, type Backend, type PhotoInput } from './types';

const STOP_COLUMNS = '*';

const asStop = (r: Record<string, unknown>): Stop => {
  const { geog: _g, moderation: _m, updated_at: _u, ...rest } = r;
  const num = (v: unknown) => (v == null ? null : Number(v));
  return {
    ...(rest as unknown as Stop),
    avg_clean: num(r.avg_clean), avg_safety: num(r.avg_safety), avg_supplies: num(r.avg_supplies),
    avg_overall: num(r.avg_overall), dump_fee_amount: num(r.dump_fee_amount),
    fuel: Object.fromEntries(Object.entries((r.fuel ?? {}) as Record<string, { price: number; at: string }>)
      .map(([g, v]) => [g, { price: Number(v.price), at: v.at }])),
  };
};

function unwrap<T>(res: { data: T; error: { message: string; code?: string } | null }): T {
  if (res.error) {
    if (res.error.code === '42501') throw new SignInRequired();
    throw new Error(res.error.message);
  }
  return res.data;
}

export class SupabaseBackend implements Backend {
  readonly mode = 'shared' as const;
  private sb: SupabaseClient;
  private current: Session | null = null;
  private listeners = new Set<(s: Session | null) => void>();

  constructor(url: string, anonKey: string) {
    this.sb = createClient(url, anonKey, {
      auth: {
        storage: Platform.OS === 'web' ? undefined : AsyncStorage,
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,
      },
    });
    this.sb.auth.onAuthStateChange((_e, session) => {
      void this.refreshSession(session?.user.id ?? null);
    });
  }

  private async refreshSession(userId: string | null) {
    if (!userId) {
      this.current = null;
    } else {
      const { data } = await this.sb.from('profiles').select('display_name,is_admin').eq('id', userId).maybeSingle();
      this.current = { userId, displayName: data?.display_name ?? 'Traveler', isAdmin: !!data?.is_admin };
    }
    this.listeners.forEach((l) => l(this.current));
  }

  private uid(): string {
    if (!this.current) throw new SignInRequired();
    return this.current.userId;
  }

  session() {
    return this.current;
  }

  onSession(cb: (s: Session | null) => void) {
    this.listeners.add(cb);
    return () => void this.listeners.delete(cb);
  }

  async signInGuest(displayName: string) {
    const name = displayName.trim() || 'Traveler';
    const { data, error } = await this.sb.auth.signInAnonymously({ options: { data: { display_name: name } } });
    if (error) throw new Error(error.message);
    if (data.user) await this.refreshSession(data.user.id);
  }

  async signOut() {
    await this.sb.auth.signOut();
  }

  async loadStops() {
    // 56 sample stops: load them all. At national scale this becomes stops_near / a bounding box.
    const rows = unwrap(await this.sb.from('locations').select(STOP_COLUMNS).limit(5000));
    return (rows as Record<string, unknown>[]).map(asStop);
  }

  async getStop(id: string) {
    const row = unwrap(await this.sb.from('locations').select(STOP_COLUMNS).eq('id', id).maybeSingle());
    return row ? asStop(row as Record<string, unknown>) : null;
  }

  onStopChanged(cb: (stop: Stop | { id: string; removed: true }) => void) {
    const ch = this.sb
      .channel(`stops-${Math.random().toString(36).slice(2)}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'locations' }, async (payload) => {
        const id = ((payload.new as { id?: string })?.id ?? (payload.old as { id?: string })?.id) as string;
        if (!id) return;
        const stop = await this.getStop(id).catch(() => null);
        cb(stop ?? { id, removed: true });
      })
      .subscribe();
    return () => void this.sb.removeChannel(ch);
  }

  async getDetail(id: string): Promise<Detail> {
    const [ratings, reports, photos, prices, fav] = await Promise.all([
      this.sb.from('ratings').select('*, profiles(display_name)').eq('location_id', id).order('created_at', { ascending: false }),
      this.sb.from('reports').select('*').eq('location_id', id).eq('status', 'open').order('created_at', { ascending: false }),
      this.sb.from('photos').select('*').eq('location_id', id).order('created_at', { ascending: false }),
      this.sb.from('fuel_prices').select('grade,price,reported_at').eq('location_id', id).order('reported_at', { ascending: false }).limit(40),
      this.current
        ? this.sb.from('favorites').select('location_id').eq('location_id', id).eq('user_id', this.current.userId)
        : Promise.resolve({ data: [], error: null }),
    ]);
    const rs: Rating[] = (unwrap(ratings) as (Rating & { profiles: { display_name: string } | null })[]).map((r) => ({
      ...r, author: r.profiles?.display_name ?? 'Traveler',
    }));
    return {
      ratings: rs,
      reports: unwrap(reports) as Detail['reports'],
      photos: (unwrap(photos) as { id: string; location_id: string; path: string; created_at: string }[]).map((p) => ({
        id: p.id, location_id: p.location_id, created_at: p.created_at,
        url: this.sb.storage.from('photos').getPublicUrl(p.path).data.publicUrl,
      })),
      priceHistory: (unwrap(prices) as Detail['priceHistory']).map((p) => ({ ...p, price: Number(p.price) })),
      myRating: this.current ? rs.find((r) => r.user_id === this.current!.userId) ?? null : null,
      favorite: ((fav.data as unknown[]) ?? []).length > 0,
    };
  }

  onDetailChanged(id: string, cb: () => void) {
    const filter = `location_id=eq.${id}`;
    const ch = this.sb.channel(`detail-${id}-${Math.random().toString(36).slice(2)}`);
    for (const table of ['ratings', 'reports', 'photos', 'fuel_prices']) {
      ch.on('postgres_changes', { event: '*', schema: 'public', table, filter }, () => cb());
    }
    ch.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'locations', filter: `id=eq.${id}` }, () => cb());
    ch.subscribe();
    return () => void this.sb.removeChannel(ch);
  }

  async addStop(input: NewStop, photo: PhotoInput | null) {
    this.uid();
    const { amenities, lat, lng, ...rest } = input;
    const row = unwrap(await this.sb.from('locations')
      .insert({ ...rest, ...amenities, geog: `SRID=4326;POINT(${lng} ${lat})` })
      .select(STOP_COLUMNS).single());
    const stop = asStop(row as Record<string, unknown>);
    if (photo) await this.addPhoto(stop.id, photo);
    return stop;
  }

  async rate(locationId: string, scores: { clean: number; safety: number; supplies: number; overall: number }, review: string) {
    const user_id = this.uid();
    unwrap(await this.sb.from('ratings').upsert(
      { location_id: locationId, user_id, ...scores, review: review.trim() || null },
      { onConflict: 'location_id,user_id' },
    ));
  }

  async report(locationId: string, issue: Stop['open_issues'][number], note: string) {
    const user_id = this.uid();
    unwrap(await this.sb.from('reports').insert({ location_id: locationId, user_id, issue, note: note.trim() || null }));
  }

  async verify(locationId: string) {
    this.uid();
    unwrap(await this.sb.rpc('verify_location', { p_location: locationId }));
  }

  async addPrice(locationId: string, grade: string, price: number) {
    const reported_by = this.uid();
    unwrap(await this.sb.from('fuel_prices').insert({ location_id: locationId, grade, price, reported_by }));
  }

  async setAmenities(locationId: string, values: Record<string, string>) {
    this.uid();
    unwrap(await this.sb.rpc('set_amenities', { p_location: locationId, p_values: values }));
  }

  async addPhoto(locationId: string, photo: PhotoInput) {
    const uid = this.uid();
    const blob = photo.file ?? (await (await fetch(photo.uri)).blob());
    const type = photo.mimeType || blob.type || 'image/jpeg';
    const ext = type.split('/')[1]?.replace('jpeg', 'jpg') || 'jpg';
    const path = `${uid}/${locationId}-${Date.now()}.${ext}`;
    const body = Platform.OS === 'web' ? blob : await blob.arrayBuffer();
    const up = await this.sb.storage.from('photos').upload(path, body, { contentType: type, upsert: false });
    if (up.error) throw new Error(up.error.message);
    unwrap(await this.sb.from('photos').insert({ location_id: locationId, user_id: uid, path }));
  }

  async setFavorite(locationId: string, on: boolean) {
    const user_id = this.uid();
    if (on) unwrap(await this.sb.from('favorites').upsert({ user_id, location_id: locationId }));
    else unwrap(await this.sb.from('favorites').delete().eq('user_id', user_id).eq('location_id', locationId));
  }

  async favorites() {
    if (!this.current) return [];
    const rows = unwrap(await this.sb.from('favorites').select('location_id').eq('user_id', this.current.userId));
    return (rows as { location_id: string }[]).map((r) => r.location_id);
  }

  async flag(target: { type: 'location' | 'rating' | 'photo'; id: string; locationId: string }, reason: string) {
    const reported_by = this.uid();
    const res = await this.sb.from('flags').insert({
      target_type: target.type, target_id: target.id, location_id: target.locationId, reason, reported_by,
    });
    if (res.error && res.error.code !== '23505') unwrap(res); // already flagged by this user: fine
  }

  async stopsAlongRoute(line: [number, number][], corridorM: number) {
    const route = { type: 'LineString', coordinates: simplifyLine(line, 40) };
    const hits = unwrap(await this.sb.rpc('stops_along_route', { route, corridor_m: corridorM }));
    return hits as { id: string; along_m: number; off_route_m: number }[];
  }

  async moderationQueue(): Promise<Flag[]> {
    const rows = unwrap(await this.sb.from('flags').select('*, locations(name)').eq('status', 'pending').order('created_at'));
    return (rows as (Flag & { locations: { name: string } | null })[]).map((f) => ({ ...f, location_name: f.locations?.name ?? null }));
  }

  async moderate(flagId: string, action: 'dismiss' | 'remove' | 'restore') {
    unwrap(await this.sb.rpc('moderate_flag', { p_flag: flagId, p_action: action }));
  }
}
