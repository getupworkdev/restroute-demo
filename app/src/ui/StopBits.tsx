// Shared pieces for a stop: list row (F2.2), map summary card (F2.1), fuel price strip (F5.6).
import { Pressable, Text, View } from 'react-native';
import { fmtPrice, fmtScore, isOutdated, isPriceStale, isReportedClosed, miles, openState } from '../logic';
import { GRADES, ISSUE_LABEL, TYPE_COLOR, TYPE_LABEL } from '../meta';
import type { Stop } from '../types';
import { Badge, Btn, C, s } from './kit';

export function TypeDot({ type }: { type: Stop['stop_type'] }) {
  return <View style={{ width: 10, height: 10, borderRadius: 5, backgroundColor: TYPE_COLOR[type] }} />;
}

export function RatingPill({ stop }: { stop: Stop }) {
  if (!stop.rating_count) return <Text style={s.muted}>No ratings yet</Text>;
  return (
    <Text style={{ fontSize: 13, color: C.ink2 }}>
      <Text style={{ color: C.amber, fontWeight: '800' }}>★ {fmtScore(stop.avg_overall)}</Text>
      <Text style={{ color: C.mute }}> ({stop.rating_count})</Text>
    </Text>
  );
}

export function OpenBadge({ stop }: { stop: Stop }) {
  if (isReportedClosed(stop)) return <Badge text="Reported closed" tone="red" />;
  const o = openState(stop);
  return <Badge text={o.label} tone={o.open ? 'green' : 'mute'} />;
}

export function PriceStrip({ stop, highlight }: { stop: Stop; highlight?: string }) {
  const entries = GRADES.filter((g) => stop.fuel[g.key]);
  if (!entries.length) return null;
  return (
    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 6 }}>
      {entries.map((g) => {
        const f = stop.fuel[g.key]!;
        const stale = isPriceStale(f.at);
        return (
          <View key={g.key} style={{
            flexDirection: 'row', gap: 4, alignItems: 'baseline', paddingHorizontal: 7, paddingVertical: 3, borderRadius: 6,
            backgroundColor: highlight === g.key ? C.amberSoft : C.bg,
          }}>
            <Text style={{ fontSize: 11, color: C.mute, fontWeight: '700' }}>{g.key === 'midgrade' ? 'MID' : g.label.toUpperCase()}</Text>
            <Text style={{ fontSize: 13, fontWeight: '800', color: stale ? C.mute : C.ink }}>{fmtPrice(f.price)}</Text>
            {stale ? <Text style={{ fontSize: 11, color: '#b45309' }}>old</Text> : null}
          </View>
        );
      })}
    </View>
  );
}

export function StopRow(props: {
  stop: Stop; distance: string | null; onPress: () => void; selected?: boolean; priceGrade?: string; lead?: string;
}) {
  const { stop } = props;
  return (
    <Pressable onPress={props.onPress} style={({ pressed }) => ({
      paddingVertical: 12, paddingHorizontal: 14, gap: 6, backgroundColor: props.selected ? '#fffbeb' : pressed ? C.bg : C.card,
      borderBottomWidth: 1, borderBottomColor: C.line,
    })}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <View style={[s.row, { flex: 1 }]}>
          <TypeDot type={stop.stop_type} />
          <Text style={{ fontSize: 15, fontWeight: '700', color: C.ink, flexShrink: 1 }} numberOfLines={1}>{stop.name}</Text>
        </View>
        {props.lead ?? props.distance ? (
          <Text style={{ fontSize: 14, fontWeight: '800', color: C.ink }}>{props.lead ?? props.distance}</Text>
        ) : null}
      </View>
      <View style={[s.row, { flexWrap: 'wrap' }]}>
        <Text style={s.muted}>{TYPE_LABEL[stop.stop_type]}{stop.highway ? ` · ${stop.highway}` : ''}</Text>
        <RatingPill stop={stop} />
        <OpenBadge stop={stop} />
        {stop.open_issues.filter((i) => i !== 'closed').map((i) => <Badge key={i} text={ISSUE_LABEL[i]} tone="red" />)}
        {isOutdated(stop) ? <Badge text="May be outdated" tone="amber" /> : null}
      </View>
      <PriceStrip stop={stop} highlight={props.priceGrade} />
    </Pressable>
  );
}

export function SummaryCard(props: { stop: Stop; distance: string | null; onOpen: () => void; onClose: () => void }) {
  const { stop } = props;
  return (
    <View style={{
      backgroundColor: C.card, borderRadius: 16, padding: 14, gap: 8, borderWidth: 1, borderColor: C.line,
      shadowColor: '#000', shadowOpacity: 0.18, shadowRadius: 18, shadowOffset: { width: 0, height: 6 }, elevation: 6,
    }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <View style={[s.row, { flex: 1 }]}>
          <TypeDot type={stop.stop_type} />
          <Text style={{ fontSize: 17, fontWeight: '800', color: C.ink, flexShrink: 1 }} numberOfLines={2}>{stop.name}</Text>
        </View>
        <Pressable onPress={props.onClose} hitSlop={10} accessibilityLabel="Close">
          <Text style={{ fontSize: 20, color: C.mute }}>×</Text>
        </Pressable>
      </View>
      <View style={[s.row, { flexWrap: 'wrap' }]}>
        <Text style={s.muted}>{TYPE_LABEL[stop.stop_type]}</Text>
        <RatingPill stop={stop} />
        <OpenBadge stop={stop} />
        {props.distance ? <Text style={{ fontWeight: '700', color: C.ink2 }}>{props.distance}</Text> : null}
      </View>
      <PriceStrip stop={stop} />
      <Btn label="View details" onPress={props.onOpen} />
    </View>
  );
}

export { miles };
