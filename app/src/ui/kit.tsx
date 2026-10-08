import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, TextInput, View, type TextInputProps, type ViewStyle } from 'react-native';
import type { Tri } from '../types';

export const C = {
  ink: '#0f172a',
  ink2: '#334155',
  mute: '#64748b',
  line: '#e2e8f0',
  bg: '#f1f5f9',
  card: '#ffffff',
  sign: '#0f172a',
  amber: '#f59e0b',
  amberSoft: '#fef3c7',
  green: '#15803d',
  greenSoft: '#dcfce7',
  red: '#b91c1c',
  redSoft: '#fee2e2',
  blue: '#1d4ed8',
  blueSoft: '#dbeafe',
};

export function Btn(props: {
  label: string; onPress: () => void; kind?: 'primary' | 'ghost' | 'danger' | 'quiet'; busy?: boolean;
  disabled?: boolean; small?: boolean; style?: ViewStyle; icon?: string;
}) {
  const kind = props.kind ?? 'primary';
  const bg = kind === 'primary' ? C.ink : kind === 'danger' ? C.red : kind === 'quiet' ? C.bg : 'transparent';
  const fg = kind === 'primary' || kind === 'danger' ? '#fff' : C.ink;
  return (
    <Pressable
      accessibilityRole="button"
      onPress={props.onPress}
      disabled={props.disabled || props.busy}
      style={({ pressed }) => [
        s.btn, props.small && s.btnSmall, { backgroundColor: bg, opacity: props.disabled ? 0.45 : pressed ? 0.8 : 1 },
        kind === 'ghost' && { borderWidth: 1, borderColor: C.line }, props.style,
      ]}
    >
      {props.busy ? <ActivityIndicator color={fg} size="small" /> : (
        <Text style={[s.btnText, props.small && { fontSize: 13 }, { color: fg }]}>
          {props.icon ? `${props.icon}  ` : ''}{props.label}
        </Text>
      )}
    </Pressable>
  );
}

export function Chip(props: { label: string; on?: boolean; onPress: () => void; tone?: 'amber' | 'default' }) {
  return (
    <Pressable
      onPress={props.onPress}
      accessibilityRole="button"
      accessibilityState={{ selected: !!props.on }}
      style={[s.chip, props.on && { backgroundColor: props.tone === 'amber' ? C.amber : C.ink, borderColor: 'transparent' }]}
    >
      <Text style={[s.chipText, props.on && { color: props.tone === 'amber' ? C.ink : '#fff' }]}>{props.label}</Text>
    </Pressable>
  );
}

export function Badge({ text, tone = 'mute' }: { text: string; tone?: 'mute' | 'green' | 'red' | 'amber' | 'blue' }) {
  const map = {
    mute: [C.bg, C.ink2], green: [C.greenSoft, C.green], red: [C.redSoft, C.red],
    amber: [C.amberSoft, '#92400e'], blue: [C.blueSoft, C.blue],
  } as const;
  const [bg, fg] = map[tone];
  return <View style={[s.badge, { backgroundColor: bg }]}><Text style={[s.badgeText, { color: fg }]}>{text}</Text></View>;
}

export function Stars({ value, onChange, size = 26 }: { value: number; onChange?: (v: number) => void; size?: number }) {
  return (
    <View style={{ flexDirection: 'row', gap: 2 }}>
      {[1, 2, 3, 4, 5].map((i) => (
        <Pressable key={i} disabled={!onChange} onPress={() => onChange?.(i)} accessibilityLabel={`${i} stars`} hitSlop={4}>
          <Text style={{ fontSize: size, color: i <= value ? C.amber : '#cbd5e1', lineHeight: size + 4 }}>★</Text>
        </Pressable>
      ))}
    </View>
  );
}

export function TriToggle({ value, onChange }: { value: Tri; onChange: (v: Tri) => void }) {
  const opts: { v: Tri; label: string }[] = [{ v: 'yes', label: 'Yes' }, { v: 'no', label: 'No' }, { v: 'unknown', label: '?' }];
  return (
    <View style={s.seg}>
      {opts.map((o) => (
        <Pressable key={o.v} onPress={() => onChange(o.v)} style={[s.segItem, value === o.v && {
          backgroundColor: o.v === 'yes' ? C.green : o.v === 'no' ? C.ink2 : '#94a3b8',
        }]}>
          <Text style={[s.segText, value === o.v && { color: '#fff' }]}>{o.label}</Text>
        </Pressable>
      ))}
    </View>
  );
}

export function Field(props: TextInputProps & { label?: string }) {
  const { label, style, ...rest } = props;
  return (
    <View style={{ gap: 6 }}>
      {label ? <Text style={s.label}>{label}</Text> : null}
      <TextInput placeholderTextColor="#94a3b8" style={[s.input, style]} {...rest} />
    </View>
  );
}

export function Section({ title, right, children }: { title: string; right?: ReactNode; children: ReactNode }) {
  return (
    <View style={s.section}>
      <View style={s.sectionHead}>
        <Text style={s.sectionTitle}>{title}</Text>
        {right}
      </View>
      {children}
    </View>
  );
}

export function Notice({ tone, text }: { tone: 'amber' | 'red' | 'blue'; text: string }) {
  const bg = tone === 'amber' ? C.amberSoft : tone === 'red' ? C.redSoft : C.blueSoft;
  const fg = tone === 'amber' ? '#92400e' : tone === 'red' ? C.red : C.blue;
  return <View style={[s.notice, { backgroundColor: bg }]}><Text style={{ color: fg, fontSize: 13, fontWeight: '600' }}>{text}</Text></View>;
}

export const s = StyleSheet.create({
  btn: { paddingHorizontal: 16, paddingVertical: 11, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  btnSmall: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 8 },
  btnText: { fontSize: 15, fontWeight: '700' },
  chip: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 999, borderWidth: 1, borderColor: C.line, backgroundColor: C.card },
  chipText: { fontSize: 13, fontWeight: '600', color: C.ink2 },
  badge: { paddingHorizontal: 8, paddingVertical: 3, borderRadius: 6, alignSelf: 'flex-start' },
  badgeText: { fontSize: 12, fontWeight: '700' },
  seg: { flexDirection: 'row', borderRadius: 8, borderWidth: 1, borderColor: C.line, overflow: 'hidden' },
  segItem: { paddingHorizontal: 10, paddingVertical: 5, minWidth: 34, alignItems: 'center' },
  segText: { fontSize: 12, fontWeight: '700', color: C.ink2 },
  label: { fontSize: 13, fontWeight: '700', color: C.ink2 },
  input: {
    borderWidth: 1, borderColor: C.line, borderRadius: 10, paddingHorizontal: 12, paddingVertical: 10,
    fontSize: 15, color: C.ink, backgroundColor: C.card,
  },
  section: { backgroundColor: C.card, borderRadius: 14, padding: 16, gap: 12, borderWidth: 1, borderColor: C.line },
  sectionHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  sectionTitle: { fontSize: 13, fontWeight: '800', color: C.mute, textTransform: 'uppercase', letterSpacing: 0.6 },
  notice: { padding: 10, borderRadius: 10 },
  h1: { fontSize: 22, fontWeight: '800', color: C.ink },
  muted: { fontSize: 13, color: C.mute },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
});
