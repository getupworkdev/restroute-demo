// Guided add flow (F3.1-F3.5): name and type, precise pin, access, hours, photo, optional details.
import * as ImagePicker from 'expo-image-picker';
import { useState } from 'react';
import { Image, Pressable, ScrollView, Switch, Text, View } from 'react-native';
import { backend, type PhotoInput } from '../backend';
import { ACCESS, AMENITY_GROUPS, DAYS, STOP_TYPES } from '../meta';
import { deviceTimeZone } from '../services';
import type { Access, AmenityKey, Day, Hours, Stop, StopType, Tri } from '../types';
import { Btn, C, Chip, Field, Notice, Section, TriToggle, s } from './kit';

type Props = {
  pin: { lat: number; lng: number } | null;
  pinFromGps: boolean;
  onUseGps: () => void;
  onPlaceOnMap: (() => void) | null;   // narrow screens: switch to the map to drag the pin
  onCancel: () => void;
  onCreated: (s: Stop) => void;
};

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

export default function AddStop({ pin, pinFromGps, onUseGps, onPlaceOnMap, onCancel, onCreated }: Props) {
  const [name, setName] = useState('');
  const [type, setType] = useState<StopType | null>(null);
  const [highway, setHighway] = useState('');
  const [access, setAccess] = useState<Access | null>(null);
  const [allDay, setAllDay] = useState(true);
  const [hours, setHours] = useState<Record<Day, { open: boolean; from: string; to: string }>>(
    Object.fromEntries(DAYS.map((d) => [d.key, { open: true, from: '06:00', to: '22:00' }])) as never,
  );
  const [amen, setAmen] = useState<Partial<Record<AmenityKey, Tri>>>({});
  const [showDetails, setShowDetails] = useState(false);
  const [photo, setPhoto] = useState<PhotoInput | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const hoursValid = allDay || DAYS.every((d) => !hours[d.key].open || (HHMM.test(hours[d.key].from) && HHMM.test(hours[d.key].to)));
  const missing = [
    name.trim().length < 2 && 'a name', !type && 'a stop type', !pin && 'a pin on the map', !access && 'access', !hoursValid && 'valid hours (HH:MM)',
  ].filter(Boolean) as string[];

  async function submit() {
    if (missing.length || !pin || !type || !access) return;
    setBusy(true); setError(null);
    try {
      const h: Hours | null = allDay ? null : Object.fromEntries(
        DAYS.filter((d) => hours[d.key].open).map((d) => [d.key, [[hours[d.key].from, hours[d.key].to]]]),
      );
      const stop = await backend.addStop({
        name: name.trim(), stop_type: type, lat: pin.lat, lng: pin.lng, highway, access,
        open_24h: allDay, hours: h, tz: deviceTimeZone(), amenities: amen,
      }, photo);
      onCreated(stop);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <ScrollView style={{ flex: 1, backgroundColor: C.bg }} contentContainerStyle={{ padding: 14, gap: 12, paddingBottom: 40 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <Text style={s.h1}>Add a stop</Text>
        <Btn small kind="quiet" label="Cancel" onPress={onCancel} />
      </View>

      <Section title="1 · Name and type">
        <Field placeholder="e.g. Exit 112 Welcome Center" value={name} onChangeText={setName} maxLength={120} />
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          {STOP_TYPES.map((t) => <Chip key={t.key} label={t.label} on={type === t.key} onPress={() => setType(t.key)} />)}
        </View>
        <Field placeholder="Highway (optional), e.g. I-75" value={highway} onChangeText={setHighway} autoCapitalize="characters" />
      </Section>

      <Section title="2 · Exact spot">
        {pin ? (
          <Text style={{ color: C.ink2 }}>
            {pinFromGps ? 'Pin dropped at your GPS position. ' : ''}Drag the red pin, or tap the map, to the entrance.
            {'\n'}<Text style={s.muted}>{pin.lat.toFixed(5)}, {pin.lng.toFixed(5)}</Text>
          </Text>
        ) : <Text style={{ color: C.ink2 }}>Tap the map where the stop is, or use your location.</Text>}
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          <Btn small kind="ghost" icon="◎" label="Use my location" onPress={onUseGps} />
          {onPlaceOnMap ? <Btn small icon="⌖" label="Place on map" onPress={onPlaceOnMap} /> : null}
        </View>
      </Section>

      <Section title="3 · Access (required)">
        {ACCESS.map((a) => (
          <Pressable key={a.key} onPress={() => setAccess(a.key)} style={[s.row, {
            padding: 10, borderRadius: 10, borderWidth: 1, borderColor: access === a.key ? C.ink : C.line,
            backgroundColor: access === a.key ? '#f8fafc' : C.card,
          }]}>
            <View style={{ width: 18, height: 18, borderRadius: 9, borderWidth: 2, borderColor: C.ink, alignItems: 'center', justifyContent: 'center' }}>
              {access === a.key ? <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: C.ink }} /> : null}
            </View>
            <Text style={{ color: C.ink, fontWeight: '600' }}>{a.label}</Text>
          </Pressable>
        ))}
      </Section>

      <Section title="4 · Hours">
        <View style={[s.row, { justifyContent: 'space-between' }]}>
          <Text style={{ color: C.ink, fontWeight: '700' }}>Open 24/7</Text>
          <Switch value={allDay} onValueChange={setAllDay} />
        </View>
        {!allDay ? DAYS.map((d) => {
          const h = hours[d.key];
          const set = (patch: Partial<typeof h>) => setHours({ ...hours, [d.key]: { ...h, ...patch } });
          return (
            <View key={d.key} style={s.row}>
              <Pressable onPress={() => set({ open: !h.open })} style={{ width: 70 }}>
                <Text style={{ fontWeight: '700', color: h.open ? C.ink : C.mute }}>{h.open ? '☑' : '☐'} {d.label}</Text>
              </Pressable>
              {h.open ? (
                <>
                  <Field value={h.from} onChangeText={(t) => set({ from: t })} style={{ width: 80, paddingVertical: 6 }} />
                  <Text style={s.muted}>to</Text>
                  <Field value={h.to} onChangeText={(t) => set({ to: t })} style={{ width: 80, paddingVertical: 6 }} />
                </>
              ) : <Text style={s.muted}>Closed</Text>}
            </View>
          );
        }) : null}
        {!allDay ? <Text style={[s.muted, { fontSize: 12 }]}>24-hour clock. Closing after midnight is fine (e.g. 18:00 to 02:00).</Text> : null}
      </Section>

      <Section title="5 · Photo">
        <Text style={{ color: C.ink2 }}>A photo of the entrance or signage helps the next traveler find it.</Text>
        {photo ? <Image source={{ uri: photo.uri }} style={{ width: '100%', height: 180, borderRadius: 10 }} resizeMode="cover" /> : null}
        <Btn kind="ghost" icon="📷" label={photo ? 'Choose another photo' : 'Add a photo'} onPress={async () => {
          const r = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], quality: 0.7 });
          if (!r.canceled && r.assets[0]) {
            const a = r.assets[0];
            setPhoto({ uri: a.uri, mimeType: a.mimeType, file: (a as { file?: Blob }).file ?? null });
          }
        }} />
      </Section>

      <Section title="6 · What's here (optional)" right={<Btn small kind="ghost" label={showDetails ? 'Hide' : 'Add details'} onPress={() => setShowDetails(!showDetails)} />}>
        {showDetails ? AMENITY_GROUPS.map((g) => (
          <View key={g.id} style={{ gap: 6 }}>
            <Text style={{ fontWeight: '800', color: C.ink }}>{g.title}</Text>
            {g.items.map((i) => (
              <View key={i.key} style={[s.row, { justifyContent: 'space-between' }]}>
                <Text style={{ color: C.ink2 }}>{i.label}</Text>
                <TriToggle value={amen[i.key] ?? 'unknown'} onChange={(v) => setAmen({ ...amen, [i.key]: v })} />
              </View>
            ))}
          </View>
        )) : <Text style={s.muted}>Anything you skip stays "unknown" and others can fill it in.</Text>}
      </Section>

      {error ? <Notice tone="red" text={error} /> : null}
      {missing.length ? <Text style={s.muted}>Still needed: {missing.join(', ')}.</Text> : null}
      <Btn label="Add stop for everyone" disabled={missing.length > 0} busy={busy} onPress={submit} />
    </ScrollView>
  );
}
