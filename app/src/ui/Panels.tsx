// Filter panel (F2.4), route planner (F2.5), account & favorites (F7.1, F7.2), moderation queue (F7.4).
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, Text, View } from 'react-native';
import { backend } from '../backend';
import { activeFilterCount, NO_FILTERS, type Filters } from '../logic';
import { AMENITY_GROUPS, STOP_TYPES } from '../meta';
import { searchPlaces, type Place } from '../services';
import type { Flag, Session, Stop } from '../types';
import { Btn, C, Chip, Field, Notice, Section, s } from './kit';

export function FiltersPanel({ filters, onChange, onClose, count }: {
  filters: Filters; onChange: (f: Filters) => void; onClose: () => void; count: number;
}) {
  const toggle = <T,>(arr: T[], v: T) => (arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v]);
  return (
    <ScrollView style={{ flex: 1, backgroundColor: C.bg }} contentContainerStyle={{ padding: 14, gap: 12, paddingBottom: 40 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <Text style={s.h1}>Filters</Text>
        <View style={s.row}>
          <Btn small kind="quiet" label="Clear all" disabled={!activeFilterCount(filters)} onPress={() => onChange(NO_FILTERS)} />
          <Btn small label={`Show ${count}`} onPress={onClose} />
        </View>
      </View>
      <Section title="Basics">
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          <Chip label="Open now" on={filters.openNow} onPress={() => onChange({ ...filters, openNow: !filters.openNow })} />
          {[0, 3, 4].map((r) => (
            <Chip key={r} label={r ? `${r}★ and up` : 'Any rating'} on={filters.minRating === r} onPress={() => onChange({ ...filters, minRating: r })} />
          ))}
          <Chip label="Include reported closed" on={filters.includeClosed} onPress={() => onChange({ ...filters, includeClosed: !filters.includeClosed })} />
        </View>
      </Section>
      <Section title="Stop type">
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          {STOP_TYPES.map((t) => (
            <Chip key={t.key} label={t.label} on={filters.types.includes(t.key)} onPress={() => onChange({ ...filters, types: toggle(filters.types, t.key) })} />
          ))}
        </View>
      </Section>
      {AMENITY_GROUPS.map((g) => (
        <Section key={g.id} title={g.title}>
          <View style={[s.row, { flexWrap: 'wrap' }]}>
            {g.items.map((i) => (
              <Chip key={i.key} label={i.label} on={filters.amenities.includes(i.key)}
                onPress={() => onChange({ ...filters, amenities: toggle(filters.amenities, i.key) })} />
            ))}
          </View>
        </Section>
      ))}
      <Text style={s.muted}>Filters combine: a stop must match every one you pick. They apply to the map, the list and route results.</Text>
    </ScrollView>
  );
}

export function PlaceInput({ placeholder, value, onPick }: { placeholder: string; value: string; onPick: (p: Place) => void }) {
  const [q, setQ] = useState(value);
  const [results, setResults] = useState<Place[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => setQ(value), [value]);
  useEffect(() => {
    if (q.trim().length < 3 || q === value) { setResults([]); return; }
    const t = setTimeout(() => {
      setBusy(true);
      searchPlaces(q).then(setResults).catch(() => setResults([])).finally(() => setBusy(false));
    }, 350);
    return () => clearTimeout(t);
  }, [q]);
  return (
    <View style={{ gap: 4 }}>
      <View>
        <Field placeholder={placeholder} value={q} onChangeText={setQ} />
        {busy ? <ActivityIndicator style={{ position: 'absolute', right: 12, top: 12 }} size="small" /> : null}
      </View>
      {results.map((r, i) => (
        <Pressable key={i} onPress={() => { setResults([]); setQ(r.name); onPick(r); }}
          style={({ pressed }) => ({ padding: 10, borderRadius: 8, backgroundColor: pressed ? C.bg : C.card, borderWidth: 1, borderColor: C.line })}>
          <Text style={{ fontWeight: '700', color: C.ink }}>{r.name}</Text>
          {r.detail ? <Text style={s.muted}>{r.detail}</Text> : null}
        </Pressable>
      ))}
    </View>
  );
}

export const ROUTE_PRESETS: { label: string; from: Place; to: Place }[] = [
  { label: 'Atlanta → Knoxville (I-75)', from: { name: 'Atlanta, GA', detail: '', lat: 33.749, lng: -84.388 }, to: { name: 'Knoxville, TN', detail: '', lat: 35.9606, lng: -83.9207 } },
  { label: 'Houston → San Antonio (I-10)', from: { name: 'Houston, TX', detail: '', lat: 29.7604, lng: -95.3698 }, to: { name: 'San Antonio, TX', detail: '', lat: 29.4241, lng: -98.4936 } },
  { label: 'Jacksonville → Savannah (I-95)', from: { name: 'Jacksonville, FL', detail: '', lat: 30.3322, lng: -81.6557 }, to: { name: 'Savannah, GA', detail: '', lat: 32.0809, lng: -81.0912 } },
  { label: 'Flagstaff → Kingman (I-40)', from: { name: 'Flagstaff, AZ', detail: '', lat: 35.1983, lng: -111.6513 }, to: { name: 'Kingman, AZ', detail: '', lat: 35.1894, lng: -114.053 } },
];

export function RouteForm(props: {
  hasGps: boolean;
  busy: boolean;
  error: string | null;
  onRoute: (from: Place | 'gps', to: Place) => void;
}) {
  const [from, setFrom] = useState<Place | 'gps' | null>(props.hasGps ? 'gps' : null);
  const [to, setTo] = useState<Place | null>(null);
  return (
    <View style={{ gap: 10 }}>
      <Text style={s.label}>From</Text>
      <View style={[s.row, { flexWrap: 'wrap' }]}>
        <Chip label="◎ My location" on={from === 'gps'} onPress={() => setFrom('gps')} />
      </View>
      <PlaceInput placeholder="…or a city / address" value={from && from !== 'gps' ? from.name : ''} onPick={(p) => setFrom(p)} />
      <Text style={s.label}>To</Text>
      <PlaceInput placeholder="Destination city or address" value={to?.name ?? ''} onPick={setTo} />
      <Btn label="Find stops along the route" disabled={!from || !to} busy={props.busy} onPress={() => from && to && props.onRoute(from, to)} />
      {props.error ? <Notice tone="red" text={props.error} /> : null}
      <Text style={[s.label, { marginTop: 6 }]}>Or try a sample corridor</Text>
      <View style={{ gap: 6 }}>
        {ROUTE_PRESETS.map((p) => (
          <Btn key={p.label} kind="ghost" small label={p.label} style={{ alignItems: 'flex-start' }} onPress={() => props.onRoute(p.from, p.to)} />
        ))}
      </View>
    </View>
  );
}

export function AccountPanel(props: {
  session: Session | null; stops: Map<string, Stop>; favorites: string[]; onOpenStop: (id: string) => void; onClose: () => void;
  onModeration: () => void; reason: string | null;
}) {
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { session } = props;
  return (
    <ScrollView style={{ flex: 1, backgroundColor: C.bg }} contentContainerStyle={{ padding: 14, gap: 12, paddingBottom: 40 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <Text style={s.h1}>{session ? `Hi, ${session.displayName}` : 'Sign in'}</Text>
        <Btn small kind="quiet" label="Close" onPress={props.onClose} />
      </View>
      {!session ? (
        <Section title="Contribute">
          {props.reason ? <Notice tone="blue" text={props.reason} /> : null}
          <Text style={{ color: C.ink2, lineHeight: 20 }}>
            Browsing is open to everyone. To add stops, rate, report or save favorites, sign in.
          </Text>
          <Field label="Name shown on your reviews" placeholder="e.g. Dana from Ohio" value={name} onChangeText={setName} maxLength={40} />
          <Btn label="Continue as guest" busy={busy} onPress={async () => {
            setBusy(true); setError(null);
            try { await backend.signInGuest(name); props.onClose(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
            finally { setBusy(false); }
          }} />
          {error ? <Notice tone="red" text={error} /> : null}
          <View style={{ gap: 6, opacity: 0.55 }}>
            <Btn kind="ghost" label="Sign in with Apple" disabled onPress={() => undefined} />
            <Btn kind="ghost" label="Sign in with Google" disabled onPress={() => undefined} />
            <Btn kind="ghost" label="Sign in with email" disabled onPress={() => undefined} />
          </View>
          <Text style={[s.muted, { fontSize: 12 }]}>
            Demo: guest accounts only. Apple, Google and email sign-in use the same Supabase Auth and come with the full build.
          </Text>
        </Section>
      ) : (
        <>
          <Section title={`Favorites (${props.favorites.length})`}>
            {props.favorites.length ? props.favorites.map((id) => {
              const st = props.stops.get(id);
              return st ? (
                <Pressable key={id} onPress={() => props.onOpenStop(id)} style={{ paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: C.line }}>
                  <Text style={{ fontWeight: '700', color: C.ink }}>★ {st.name}</Text>
                </Pressable>
              ) : null;
            }) : <Text style={s.muted}>Tap “Save” on any stop. Favorites sync to your account on every device.</Text>}
          </Section>
          {session.isAdmin ? <Btn kind="ghost" icon="⚑" label="Moderation queue" onPress={props.onModeration} /> : null}
          <Btn kind="quiet" label="Sign out" onPress={() => backend.signOut()} />
        </>
      )}
    </ScrollView>
  );
}

export function ModerationPanel({ onClose, onOpenStop }: { onClose: () => void; onOpenStop: (id: string) => void }) {
  const [items, setItems] = useState<Flag[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = () => backend.moderationQueue().then(setItems).catch((e) => setError(String(e.message ?? e)));
  useEffect(() => { void load(); }, []);
  return (
    <ScrollView style={{ flex: 1, backgroundColor: C.bg }} contentContainerStyle={{ padding: 14, gap: 12 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <Text style={s.h1}>Moderation</Text>
        <Btn small kind="quiet" label="Close" onPress={onClose} />
      </View>
      {error ? <Notice tone="red" text={error} /> : null}
      {items && !items.length ? <Text style={s.muted}>Nothing flagged. Locations flagged by three different people are hidden until reviewed here.</Text> : null}
      {items?.map((f) => (
        <Section key={f.id} title={`${f.target_type} · ${f.reason}`}>
          {f.location_id ? (
            <Pressable onPress={() => onOpenStop(f.location_id!)}><Text style={{ fontWeight: '700', color: C.blue }}>{f.location_name ?? 'Open location'}</Text></Pressable>
          ) : null}
          <View style={s.row}>
            <Btn small kind="ghost" label="Keep" onPress={() => backend.moderate(f.id, 'dismiss').then(load)} />
            <Btn small kind="danger" label="Remove" onPress={() => backend.moderate(f.id, 'remove').then(load)} />
            {f.target_type === 'location' ? <Btn small kind="ghost" label="Restore" onPress={() => backend.moderate(f.id, 'restore').then(load)} /> : null}
          </View>
        </Section>
      ))}
    </ScrollView>
  );
}
