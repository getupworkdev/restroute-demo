import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { ActivityIndicator, FlatList, Platform, Pressable, SafeAreaView, ScrollView, Text, TextInput, useWindowDimensions, View, type ViewStyle } from 'react-native';
import { backend } from './src/backend';
import {
  activeFilterCount, applyFilters, distanceM, miles, NO_FILTERS, parseHighway, sortStops, textMatch,
  type Filters, type SortKey,
} from './src/logic';
import { AMENITY_LABEL, GRADES, QUICK_AMENITIES, ROUTE_CORRIDOR_M } from './src/meta';
import StopMap from './src/map/StopMap';
import type { Focus } from './src/map/types';
import { drivingRoute, myPosition, searchPlaces, type Place } from './src/services';
import type { LngLat, RouteHit, Session, Stop } from './src/types';
import AddStop from './src/ui/AddStop';
import { Btn, C, Chip, Notice, s } from './src/ui/kit';
import { AccountPanel, FiltersPanel, ModerationPanel, RouteForm } from './src/ui/Panels';
import StopDetail from './src/ui/StopDetail';
import { StopRow, SummaryCard } from './src/ui/StopBits';

type Panel = null | 'detail' | 'add' | 'filters' | 'account' | 'moderation';
type Query = null | { kind: 'highway'; value: string } | { kind: 'place'; place: Place } | { kind: 'text'; value: string };
type RouteState = { line: LngLat[]; hits: RouteHit[]; label: string; distance: number; duration: number };

const CITY_RADIUS_M = 160934; // 100 miles around a searched city

export default function App() {
  const { width } = useWindowDimensions();
  const wide = width >= 900;

  const [stops, setStops] = useState<Map<string, Stop>>(new Map());
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [session, setSession] = useState<Session | null>(backend.session());
  const [favorites, setFavorites] = useState<string[]>([]);
  const [user, setUser] = useState<{ lat: number; lng: number } | null>(null);
  const [center, setCenter] = useState<{ lat: number; lng: number } | null>(null);
  const [filters, setFilters] = useState<Filters>(NO_FILTERS);
  const [sort, setSort] = useState<SortKey>('nearest');
  const [query, setQuery] = useState<Query>(null);
  const [searchText, setSearchText] = useState('');
  const [searchBusy, setSearchBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [mode, setMode] = useState<'nearby' | 'route'>('nearby');
  const [route, setRoute] = useState<RouteState | null>(null);
  const [routeBusy, setRouteBusy] = useState(false);
  const [routeError, setRouteError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [signInReason, setSignInReason] = useState<string | null>(null);
  const [narrowView, setNarrowView] = useState<'map' | 'list'>('map');
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(null);
  const [pinFromGps, setPinFromGps] = useState(false);
  const [pickingOnMap, setPickingOnMap] = useState(false);
  const [focus, setFocus] = useState<Focus | null>(null);
  const [live, setLive] = useState<string | null>(null);
  const focusN = useRef(0);
  const flyTo = (f: Omit<Focus & { kind: 'point' }, 'n'> | Omit<Focus & { kind: 'bounds' }, 'n'>) =>
    setFocus({ ...f, n: ++focusN.current } as Focus);

  // ------------------------------------------------------------ data

  useEffect(() => {
    backend.loadStops()
      .then((list) => {
        setStops(new Map(list.map((x) => [x.id, x])));
        if (list.length) flyTo({ kind: 'bounds', points: list.map((x) => [x.lng, x.lat] as LngLat) });
      })
      .catch((e) => setLoadError(String(e.message ?? e)))
      .finally(() => setLoading(false));
    // Realtime: another device adds, rates, reports or verifies -> this map updates.
    return backend.onStopChanged((change) => {
      setStops((prev) => {
        const next = new Map(prev);
        if ('removed' in change) next.delete(change.id);
        else {
          if (backend.mode === 'shared') setLive(prev.has(change.id) ? `Updated live: ${change.name}` : `New stop added: ${change.name}`);
          next.set(change.id, change);
        }
        return next;
      });
    });
  }, []);

  useEffect(() => backend.onSession(setSession), []);
  const refreshFavorites = useCallback(() => { backend.favorites().then(setFavorites).catch(() => setFavorites([])); }, []);
  useEffect(refreshFavorites, [session?.userId]);

  useEffect(() => {
    if (!live) return;
    const t = setTimeout(() => setLive(null), 3500);
    return () => clearTimeout(t);
  }, [live]);

  // ------------------------------------------------------------ derived lists

  const ref = query?.kind === 'place' ? query.place : user;
  const distOf = useCallback((x: Stop) => (ref ? distanceM(ref, x) : center ? distanceM(center, x) : 0), [ref, center]);

  const all = useMemo(() => [...stops.values()], [stops]);

  const nearby = useMemo(() => {
    let list = applyFilters(all, filters);
    if (query?.kind === 'highway') list = list.filter((x) => x.highway === query.value);
    if (query?.kind === 'place') list = list.filter((x) => distanceM(query.place, x) <= CITY_RADIUS_M);
    if (query?.kind === 'text') list = list.filter((x) => textMatch(x, query.value));
    return sortStops(list, sort, distOf);
  }, [all, filters, query, sort, distOf]);

  const routeList = useMemo(() => {
    if (!route) return [];
    const byId = new Map(route.hits.map((h) => [h.id, h]));
    const list = applyFilters(route.hits.map((h) => stops.get(h.id)).filter(Boolean) as Stop[], filters);
    const along = (x: Stop) => byId.get(x.id)!.along_m;
    return sort === 'nearest' || sort === 'rating' ? [...list].sort((a, b) => along(a) - along(b)) : sortStops(list, sort, along);
  }, [route, stops, filters, sort]);

  const visible = mode === 'route' && route ? routeList : nearby;
  const selected = selectedId ? stops.get(selectedId) ?? null : null;
  const routeAlong = (id: string) => route?.hits.find((h) => h.id === id)?.along_m;

  // ------------------------------------------------------------ actions

  async function nearMe() {
    setSearchBusy(true); setNotice(null);
    try {
      const p = await myPosition();
      setUser(p); setQuery(null); setSearchText(''); setSort('nearest');
      flyTo({ kind: 'point', lat: p.lat, lng: p.lng, zoom: 9 });
    } catch (e) {
      setNotice(`${e instanceof Error ? e.message : e}. Showing all stops instead.`);
    } finally { setSearchBusy(false); }
  }

  async function runSearch() {
    const q = searchText.trim();
    setNotice(null);
    if (!q) { setQuery(null); return; }
    setMode('nearby');
    const hw = parseHighway(q);
    if (hw) {
      setQuery({ kind: 'highway', value: hw });
      const pts = all.filter((x) => x.highway === hw).map((x) => [x.lng, x.lat] as LngLat);
      if (pts.length) flyTo({ kind: 'bounds', points: pts }); else setNotice(`No stops on ${hw} yet.`);
      return;
    }
    if (all.some((x) => textMatch(x, q))) { setQuery({ kind: 'text', value: q }); return; }
    setSearchBusy(true);
    try {
      const [p] = await searchPlaces(q);
      if (!p) { setNotice(`Couldn't find “${q}”.`); return; }
      setQuery({ kind: 'place', place: p }); setSort('nearest');
      flyTo({ kind: 'point', lat: p.lat, lng: p.lng, zoom: 8 });
    } catch (e) {
      setNotice(e instanceof Error ? e.message : String(e));
    } finally { setSearchBusy(false); }
  }

  async function runRoute(from: Place | 'gps', to: Place) {
    setRouteBusy(true); setRouteError(null);
    try {
      let start: { lat: number; lng: number };
      if (from === 'gps') { start = user ?? await myPosition(); setUser(start); } else start = from;
      const r = await drivingRoute(start, to);
      const hits = await backend.stopsAlongRoute(r.line, ROUTE_CORRIDOR_M);
      setRoute({ line: r.line, hits, label: `${from === 'gps' ? 'My location' : from.name} → ${to.name}`, distance: r.distance, duration: r.duration });
      setSort('nearest');
      flyTo({ kind: 'bounds', points: r.line });
      if (!wide) setNarrowView('list');
    } catch (e) {
      setRouteError(e instanceof Error ? e.message : String(e));
    } finally { setRouteBusy(false); }
  }

  function openStop(id: string) {
    setSelectedId(id);
    setPanel('detail');
    const st = stops.get(id);
    if (st) flyTo({ kind: 'point', lat: st.lat, lng: st.lng, zoom: 12 });
  }

  function needSignIn(reason = 'Sign in to add stops, rate, report and save favorites.') {
    setSignInReason(reason);
    setPanel('account');
  }

  async function startAdd() {
    if (!session) { needSignIn('Sign in to add a stop.'); return; }
    setSelectedId(null); setPanel('add'); setPin(null); setPinFromGps(false);
    // F3.2: the pin starts at the GPS position when available; otherwise the map centre.
    try {
      const p = await myPosition();
      setUser(p); setPin(p); setPinFromGps(true);
      flyTo({ kind: 'point', lat: p.lat, lng: p.lng, zoom: 15 });
    } catch {
      const c = center ?? { lat: 34.3, lng: -84.6 };
      setPin(c);
    }
  }

  // ------------------------------------------------------------ pieces

  const header = (
    <View style={{ backgroundColor: C.sign, paddingHorizontal: 14, paddingTop: Platform.OS === 'web' ? 12 : 4, paddingBottom: 12, gap: 10 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <View style={s.row}>
          <View style={{ width: 30, height: 30, borderRadius: 8, backgroundColor: C.amber, alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ fontWeight: '900', color: C.ink, fontSize: 15 }}>RR</Text>
          </View>
          <View>
            <Text style={{ color: '#fff', fontWeight: '900', fontSize: 18, letterSpacing: 0.3 }}>RestRoute</Text>
            <Text style={{ color: '#94a3b8', fontSize: 11 }}>
              {backend.mode === 'shared' ? '● Live · shared database' : 'Sample mode · changes stay in this browser'}
            </Text>
          </View>
        </View>
        <View style={s.row}>
          <Btn small kind="quiet" icon="＋" label="Add stop" onPress={startAdd} style={{ backgroundColor: C.amber }} />
          <Pressable onPress={() => { setSignInReason(null); setPanel('account'); }} style={{ paddingHorizontal: 10, paddingVertical: 7, borderRadius: 8, borderWidth: 1, borderColor: '#334155' }}>
            <Text style={{ color: '#fff', fontWeight: '700', fontSize: 13 }}>{session ? `☺ ${session.displayName}` : 'Sign in'}</Text>
          </Pressable>
        </View>
      </View>
      <View style={s.row}>
        <TextInput
          value={searchText} onChangeText={setSearchText} onSubmitEditing={runSearch} returnKeyType="search"
          placeholder="City, highway (I-75) or stop name" placeholderTextColor="#64748b"
          style={{ flex: 1, backgroundColor: '#fff', borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10, fontSize: 15 }}
        />
        <Btn small kind="quiet" label="Go" busy={searchBusy} onPress={runSearch} style={{ paddingVertical: 11 }} />
        <Btn small kind="quiet" label={wide ? '◎ Near me' : '◎'} onPress={nearMe} style={{ paddingVertical: 11, paddingHorizontal: 10 }} />
      </View>
    </View>
  );

  const nFilters = activeFilterCount(filters);
  const filterBar = (
    <View style={{ backgroundColor: C.card, borderBottomWidth: 1, borderBottomColor: C.line }}>
      <View style={{ flexDirection: 'row', padding: 10, gap: 8 }}>
        {(['nearby', 'route'] as const).map((m) => (
          <Pressable key={m} onPress={() => setMode(m)} style={{
            flex: 1, paddingVertical: 8, borderRadius: 8, alignItems: 'center', backgroundColor: mode === m ? C.ink : C.bg,
          }}>
            <Text style={{ fontWeight: '800', color: mode === m ? '#fff' : C.ink2 }}>{m === 'nearby' ? 'Stops' : 'Along my route'}</Text>
          </Pressable>
        ))}
      </View>
      <ChipRow wide={wide} style={{ paddingHorizontal: 10, paddingBottom: 10 }}>
        <Chip label={`☰ Filters${nFilters ? ` (${nFilters})` : ''}`} on={nFilters > 0} tone="amber" onPress={() => setPanel('filters')} />
        <Chip label="Open now" on={filters.openNow} onPress={() => setFilters({ ...filters, openNow: !filters.openNow })} />
        {QUICK_AMENITIES.map((a) => (
          <Chip key={a} label={AMENITY_LABEL[a]} on={filters.amenities.includes(a)} onPress={() => setFilters({
            ...filters, amenities: filters.amenities.includes(a) ? filters.amenities.filter((x) => x !== a) : [...filters.amenities, a],
          })} />
        ))}
        {nFilters ? <Chip label="✕ Clear" onPress={() => setFilters(NO_FILTERS)} /> : null}
      </ChipRow>
    </View>
  );

  const sortBar = (
    <ChipRow wide={wide} style={{ padding: 10, alignItems: 'center' }}>
      <Text style={[s.muted, { marginRight: 2 }]}>Sort</Text>
      <Chip label={mode === 'route' ? 'Along route' : 'Nearest'} on={sort === 'nearest'} onPress={() => setSort('nearest')} />
      {mode === 'nearby' ? <Chip label="Top rated" on={sort === 'rating'} onPress={() => setSort('rating')} /> : null}
      {GRADES.map((g) => (
        <Chip key={g.key} label={`$ ${g.label}`} on={sort === `price:${g.key}`} onPress={() => setSort(`price:${g.key}`)} />
      ))}
    </ChipRow>
  );

  const queryLine = query ? (
    <View style={[s.row, { paddingHorizontal: 12, paddingTop: 10 }]}>
      <Text style={{ color: C.ink2, flex: 1 }}>
        {query.kind === 'highway' ? `Stops on ${query.value}` : query.kind === 'place' ? `Within 100 mi of ${query.place.name}` : `Matching “${query.value}”`}
      </Text>
      <Btn small kind="quiet" label="✕ Clear" onPress={() => { setQuery(null); setSearchText(''); }} />
    </View>
  ) : null;

  const list = (
    <View style={{ flex: 1, backgroundColor: C.card }}>
      {mode === 'route' ? (
        <View style={{ padding: 12, gap: 8, borderBottomWidth: 1, borderBottomColor: C.line }}>
          {route ? (
            <View style={[s.row, { justifyContent: 'space-between' }]}>
              <View style={{ flex: 1 }}>
                <Text style={{ fontWeight: '800', color: C.ink }}>{route.label}</Text>
                <Text style={s.muted}>{miles(route.distance)} · {Math.round(route.duration / 3600 * 10) / 10} h · {routeList.length} stops within 1 mi of the route</Text>
              </View>
              <Btn small kind="ghost" label="Change" onPress={() => { setRoute(null); setRouteError(null); }} />
            </View>
          ) : (
            <RouteForm hasGps={!!user} busy={routeBusy} error={routeError} onRoute={runRoute} />
          )}
        </View>
      ) : queryLine}
      {notice ? <View style={{ padding: 10 }}><Notice tone="amber" text={notice} /></View> : null}
      {mode === 'nearby' || route ? sortBar : null}
      {loading ? <ActivityIndicator style={{ marginTop: 30 }} /> : null}
      {loadError ? <View style={{ padding: 12 }}><Notice tone="red" text={`Couldn't load stops: ${loadError}`} /></View> : null}
      {mode === 'nearby' || route ? (
        <FlatList
          data={visible}
          keyExtractor={(x) => x.id}
          contentContainerStyle={{ paddingBottom: wide ? 20 : 90 }}
          renderItem={({ item }) => {
            const along = mode === 'route' ? routeAlong(item.id) : undefined;
            return (
              <StopRow
                stop={item}
                selected={item.id === selectedId}
                distance={ref ? miles(distanceM(ref, item)) : null}
                lead={along != null ? `in ${miles(along)}` : undefined}
                priceGrade={sort.startsWith('price:') ? sort.slice(6) : undefined}
                onPress={() => openStop(item.id)}
              />
            );
          }}
          ListEmptyComponent={!loading ? <Text style={[s.muted, { padding: 20, textAlign: 'center' }]}>No stops match. Try clearing filters.</Text> : null}
        />
      ) : null}
    </View>
  );

  const panelView = (() => {
    if (panel === 'detail' && selected) {
      return (
        <StopDetail
          key={selected.id} stop={selected} session={session}
          distanceM={mode === 'route' && routeAlong(selected.id) != null ? routeAlong(selected.id)! : ref ? distanceM(ref, selected) : null}
          onBack={() => { setPanel(null); if (!wide) setSelectedId(null); }}
          onNeedSignIn={() => needSignIn()} onFavoriteChanged={refreshFavorites}
        />
      );
    }
    if (panel === 'add') {
      return (
        <AddStop
          pin={pin} pinFromGps={pinFromGps}
          onUseGps={async () => {
            try { const p = await myPosition(); setUser(p); setPin(p); setPinFromGps(true); flyTo({ kind: 'point', lat: p.lat, lng: p.lng, zoom: 16 }); }
            catch (e) { setNotice(e instanceof Error ? e.message : String(e)); }
          }}
          onPlaceOnMap={wide ? null : () => setPickingOnMap(true)}
          onCancel={() => { setPanel(null); setPin(null); }}
          onCreated={(st) => {
            setStops((prev) => new Map(prev).set(st.id, st));
            setPin(null); setPanel('detail'); setSelectedId(st.id);
            setLive(`Added: ${st.name}`);
          }}
        />
      );
    }
    if (panel === 'filters') return <FiltersPanel filters={filters} onChange={setFilters} onClose={() => setPanel(null)} count={visible.length} />;
    if (panel === 'account') {
      return (
        <AccountPanel session={session} stops={stops} favorites={favorites} reason={signInReason}
          onOpenStop={openStop} onClose={() => setPanel(selectedId ? 'detail' : null)} onModeration={() => setPanel('moderation')} />
      );
    }
    if (panel === 'moderation') return <ModerationPanel onClose={() => setPanel('account')} onOpenStop={openStop} />;
    return null;
  })();

  const map = (
    <View style={{ flex: 1 }}>
      <StopMap
        stops={visible}
        selectedId={selectedId}
        onSelect={(id) => { setSelectedId(id); if (wide && id) setPanel('detail'); if (wide && !id && panel === 'detail') setPanel(null); }}
        user={user}
        route={mode === 'route' && route ? route.line : null}
        focus={focus}
        pick={panel === 'add' ? pin : null}
        onPick={(lat, lng) => { setPin({ lat, lng }); setPinFromGps(false); }}
        onCenterChange={setCenter}
      />
      {live ? (
        <View style={{ position: 'absolute', top: 12, alignSelf: 'center', backgroundColor: C.ink, paddingHorizontal: 14, paddingVertical: 8, borderRadius: 999 }}>
          <Text style={{ color: '#fff', fontWeight: '700' }}>⚡ {live}</Text>
        </View>
      ) : null}
      {backend.mode === 'shared' ? null : (
        <View style={{ position: 'absolute', left: 10, bottom: 10, backgroundColor: 'rgba(255,255,255,0.92)', padding: 6, borderRadius: 6 }}>
          <Text style={{ fontSize: 11, color: C.ink2 }}>Sample stops for the demo, not real places</Text>
        </View>
      )}
    </View>
  );

  // ------------------------------------------------------------ layout

  if (wide) {
    return (
      <SafeAreaView style={{ flex: 1, backgroundColor: C.sign }}>
        <StatusBar style="light" />
        <View style={{ flex: 1, flexDirection: 'row' }}>
          <View style={{ width: 440, backgroundColor: C.bg, borderRightWidth: 1, borderRightColor: C.line }}>
            {header}
            {panelView ?? (<>{filterBar}{list}</>)}
          </View>
          <View style={{ flex: 1 }}>
            {map}
            <SampleNote />
          </View>
        </View>
      </SafeAreaView>
    );
  }

  // Phone layout: map or list, with panels full screen. Placing a pin shows the map with a Done bar.
  const showMap = (panel === null && narrowView === 'map') || (panel === 'add' && pickingOnMap);
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: C.sign }}>
      <StatusBar style="light" />
      {panel && !(panel === 'add' && pickingOnMap) ? (
        <View style={{ flex: 1, backgroundColor: C.bg }}>{panelView}</View>
      ) : (
        <View style={{ flex: 1, backgroundColor: C.bg }}>
          {panel === 'add' ? null : header}
          {panel === 'add' ? null : filterBar}
          <View style={{ flex: 1 }}>
            {showMap ? map : list}
            {showMap && panel === null && selected ? (
              <View style={{ position: 'absolute', left: 10, right: 10, bottom: 70 }}>
                <SummaryCard stop={selected} distance={ref ? miles(distanceM(ref, selected)) : null}
                  onOpen={() => setPanel('detail')} onClose={() => setSelectedId(null)} />
              </View>
            ) : null}
            {panel === 'add' && pickingOnMap ? (
              <View style={{ position: 'absolute', left: 10, right: 10, bottom: 20, gap: 8 }}>
                <Notice tone="blue" text="Drag the red pin, or tap the map, to the stop's entrance." />
                <Btn label="Done – use this spot" onPress={() => setPickingOnMap(false)} />
              </View>
            ) : null}
            {panel === null ? (
              <View style={{ position: 'absolute', bottom: 16, alignSelf: 'center', flexDirection: 'row', backgroundColor: C.ink, borderRadius: 999, padding: 4 }}>
                {(['map', 'list'] as const).map((v) => (
                  <Pressable key={v} onPress={() => setNarrowView(v)} style={{ paddingHorizontal: 18, paddingVertical: 8, borderRadius: 999, backgroundColor: narrowView === v ? C.amber : 'transparent' }}>
                    <Text style={{ fontWeight: '800', color: narrowView === v ? C.ink : '#fff' }}>{v === 'map' ? 'Map' : `List (${visible.length})`}</Text>
                  </Pressable>
                ))}
              </View>
            ) : null}
          </View>
        </View>
      )}
    </SafeAreaView>
  );
}

// Chips wrap on wide screens and scroll sideways on phones, so the map keeps its height.
function ChipRow({ wide, style, children }: { wide: boolean; style: ViewStyle; children: ReactNode }) {
  if (wide) return <View style={[{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }, style]}>{children}</View>;
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={[{ gap: 6 }, style]}>
      {children}
    </ScrollView>
  );
}

function SampleNote() {
  if (backend.mode !== 'shared') return null;
  return (
    <View style={{ position: 'absolute', left: 10, bottom: 10, backgroundColor: 'rgba(255,255,255,0.92)', paddingHorizontal: 8, paddingVertical: 5, borderRadius: 6 }}>
      <Text style={{ fontSize: 11, color: C.ink2 }}>Demo data: sample stops along I-75, I-95, I-10 and I-40, not real places</Text>
    </View>
  );
}
