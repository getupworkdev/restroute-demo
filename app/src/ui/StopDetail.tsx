// Full location detail: freshness (F4.3, F4.4), ratings and reviews (F4.1, F4.2), fuel prices (F5.6),
// amenities and RV services (F5, F6), photos (F3.5), favorites (F7.2) and flagging (F7.3).
import * as ImagePicker from 'expo-image-picker';
import { useCallback, useEffect, useState } from 'react';
import { Image, Pressable, ScrollView, Text, TextInput, View } from 'react-native';
import { backend } from '../backend';
import { ago, fmtPrice, fmtScore, hoursText, isOutdated, isPriceStale, miles, openState } from '../logic';
import { ACCESS, AMENITY_GROUPS, DAYS, GRADES, ISSUE_LABEL, ISSUES, STALE_DAYS, TYPE_LABEL } from '../meta';
import type { AmenityKey, Detail, Grade, Issue, Session, Stop, Tri } from '../types';
import { Badge, Btn, C, Chip, Field, Notice, Section, Stars, TriToggle, s } from './kit';
import { OpenBadge, TypeDot } from './StopBits';

type Props = {
  stop: Stop;
  session: Session | null;
  distanceM: number | null;
  onBack: () => void;
  onNeedSignIn: () => void;
  onFavoriteChanged: () => void;
};

export default function StopDetail({ stop, session, distanceM, onBack, onNeedSignIn, onFavoriteChanged }: Props) {
  const [detail, setDetail] = useState<Detail | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);

  const load = useCallback(() => {
    backend.getDetail(stop.id).then(setDetail).catch((e) => setError(String(e.message ?? e)));
  }, [stop.id, session?.userId]);

  useEffect(() => {
    setDetail(null);
    load();
    return backend.onDetailChanged(stop.id, load);
  }, [load]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  // Every write needs an account (F7.1); without one, open sign-in instead.
  async function act(key: string, fn: () => Promise<void>, done?: string) {
    if (!session) { onNeedSignIn(); return; }
    setBusy(key); setError(null);
    try {
      await fn();
      if (done) setToast(done);
      load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  const outdated = isOutdated(stop);
  const open = openState(stop);

  return (
    <ScrollView style={{ flex: 1, backgroundColor: C.bg }} contentContainerStyle={{ padding: 14, gap: 12, paddingBottom: 40 }}>
      <View style={[s.row, { justifyContent: 'space-between' }]}>
        <Btn label="Back" icon="‹" kind="quiet" small onPress={onBack} />
        <View style={s.row}>
          <Btn small kind={detail?.favorite ? 'primary' : 'ghost'} icon={detail?.favorite ? '★' : '☆'}
            label={detail?.favorite ? 'Saved' : 'Save'} busy={busy === 'fav'}
            onPress={() => act('fav', async () => { await backend.setFavorite(stop.id, !detail?.favorite); onFavoriteChanged(); })} />
          <FlagButton label="Flag" onFlag={(reason) => act('flag', () => backend.flag({ type: 'location', id: stop.id, locationId: stop.id }, reason), 'Thanks, sent to moderation')} />
        </View>
      </View>

      <View style={{ gap: 6 }}>
        <View style={s.row}><TypeDot type={stop.stop_type} /><Text style={s.muted}>{TYPE_LABEL[stop.stop_type]}{stop.highway ? ` · ${stop.highway}` : ''}{stop.state ? ` · ${stop.state}` : ''}</Text></View>
        <Text style={s.h1}>{stop.name}</Text>
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          <OpenBadge stop={stop} />
          {stop.rating_count ? <Badge text={`★ ${fmtScore(stop.avg_overall)} · ${stop.rating_count} rating${stop.rating_count === 1 ? '' : 's'}`} tone="amber" /> : <Badge text="No ratings yet" />}
          {distanceM != null ? <Badge text={miles(distanceM)} tone="blue" /> : null}
        </View>
      </View>

      {toast ? <Notice tone="blue" text={toast} /> : null}
      {error ? <Notice tone="red" text={error} /> : null}

      {/* F4.3 / F4.4 freshness */}
      <Section title="Is it still good?">
        <Text style={{ fontSize: 15, color: C.ink }}>
          Last verified <Text style={{ fontWeight: '800' }}>{ago(stop.last_verified_at)}</Text>
        </Text>
        {outdated ? <Notice tone="amber" text={`Information may be outdated: nobody has confirmed this stop in over ${STALE_DAYS} days.`} /> : null}
        {(detail?.reports ?? []).map((r) => (
          <View key={r.id} style={{ backgroundColor: C.redSoft, borderRadius: 10, padding: 10, gap: 2 }}>
            <Text style={{ color: C.red, fontWeight: '800' }}>{ISSUE_LABEL[r.issue]}{r.issue === 'closed' ? ' · hidden from default results' : ''}</Text>
            {r.note ? <Text style={{ color: C.ink2 }}>{r.note}</Text> : null}
            <Text style={s.muted}>Reported {ago(r.created_at)}</Text>
          </View>
        ))}
        <View style={[s.row, { flexWrap: 'wrap' }]}>
          <Btn icon="✓" label="I was here – still good" busy={busy === 'verify'}
            onPress={() => act('verify', () => backend.verify(stop.id), 'Thanks! Stamp refreshed for everyone.')} />
          <ReportButton busy={busy === 'report'} onReport={(issue, note) => act('report', () => backend.report(stop.id, issue, note), 'Report posted')} />
        </View>
      </Section>

      <Section title="Access & hours">
        <Text style={{ fontSize: 15, fontWeight: '700', color: C.ink }}>{ACCESS.find((a) => a.key === stop.access)?.label}</Text>
        <Text style={{ color: open.open ? C.green : C.ink2, fontWeight: '700' }}>{open.label}</Text>
        {!stop.open_24h && stop.hours ? (
          <View style={{ gap: 2 }}>
            {hoursText(stop.hours).map((h) => (
              <View key={h.day} style={[s.row, { justifyContent: 'space-between' }]}>
                <Text style={s.muted}>{DAYS.find((d) => d.key === h.day)?.label}</Text>
                <Text style={{ color: C.ink2, fontSize: 13 }}>{h.text}</Text>
              </View>
            ))}
            <Text style={[s.muted, { fontSize: 11 }]}>Local time ({stop.tz.replace('_', ' ')})</Text>
          </View>
        ) : null}
      </Section>

      <RatingsSection stop={stop} detail={detail} busy={busy === 'rate'}
        onRate={(sc, review) => act('rate', () => backend.rate(stop.id, sc, review), 'Rating saved. Averages updated for everyone.')}
        onFlag={(ratingId, reason) => act('flag', () => backend.flag({ type: 'rating', id: ratingId, locationId: stop.id }, reason), 'Thanks, sent to moderation')}
        signedIn={!!session} onNeedSignIn={onNeedSignIn} />

      {stop.gas === 'yes' || stop.diesel === 'yes' || Object.keys(stop.fuel).length ? (
        <FuelSection stop={stop} busy={busy === 'price'}
          onPrice={(g, p) => act('price', () => backend.addPrice(stop.id, g, p), 'Price posted')} />
      ) : null}

      <AmenitiesSection stop={stop} busy={busy === 'amen'}
        onSave={(vals) => act('amen', () => backend.setAmenities(stop.id, vals), 'Details updated')} />

      <Section title={`Photos (${detail?.photos.length ?? stop.photo_count})`} right={
        <Btn small kind="ghost" icon="＋" label="Add photo" busy={busy === 'photo'} onPress={async () => {
          if (!session) { onNeedSignIn(); return; }
          const r = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], quality: 0.7 });
          if (r.canceled || !r.assets[0]) return;
          const a = r.assets[0];
          act('photo', () => backend.addPhoto(stop.id, { uri: a.uri, mimeType: a.mimeType, file: (a as { file?: Blob }).file ?? null }), 'Photo uploaded');
        }} />
      }>
        {detail?.photos.length ? (
          <ScrollView horizontal contentContainerStyle={{ gap: 8 }}>
            {detail.photos.map((p) => (
              <Image key={p.id} source={{ uri: p.url }} style={{ width: 160, height: 120, borderRadius: 10, backgroundColor: C.bg }} />
            ))}
          </ScrollView>
        ) : <Text style={s.muted}>No photos yet. A photo of the entrance or signage helps the next traveler.</Text>}
      </Section>

      <Text style={[s.muted, { textAlign: 'center', fontSize: 12 }]}>Added {ago(stop.created_at)}</Text>
    </ScrollView>
  );
}

function ReportButton({ onReport, busy }: { onReport: (i: Issue, note: string) => void; busy: boolean }) {
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  if (!open) return <Btn kind="ghost" icon="!" label="Report an issue" onPress={() => setOpen(true)} busy={busy} />;
  return (
    <View style={{ gap: 8, width: '100%' }}>
      <Text style={s.label}>What's wrong? One tap posts it.</Text>
      <Field placeholder="Optional note (e.g. which stall)" value={note} onChangeText={setNote} />
      <View style={[s.row, { flexWrap: 'wrap' }]}>
        {ISSUES.map((i) => (
          <Chip key={i.key} label={i.label} onPress={() => { onReport(i.key, note); setOpen(false); setNote(''); }} />
        ))}
        <Btn small kind="quiet" label="Cancel" onPress={() => setOpen(false)} />
      </View>
    </View>
  );
}

function FlagButton({ label, onFlag }: { label: string; onFlag: (reason: string) => void }) {
  const [open, setOpen] = useState(false);
  if (!open) return <Btn small kind="ghost" icon="⚑" label={label} onPress={() => setOpen(true)} />;
  return (
    <View style={[s.row, { flexWrap: 'wrap', justifyContent: 'flex-end', maxWidth: 260 }]}>
      {['Wrong info', 'Spam / fake', 'Offensive'].map((r) => (
        <Chip key={r} label={r} onPress={() => { onFlag(r); setOpen(false); }} />
      ))}
      <Chip label="Cancel" onPress={() => setOpen(false)} />
    </View>
  );
}

const SCORE_LABELS: { key: 'clean' | 'safety' | 'supplies' | 'overall'; label: string }[] = [
  { key: 'clean', label: 'Cleanliness' },
  { key: 'safety', label: 'Safety / lighting' },
  { key: 'supplies', label: 'Supplies stocked' },
  { key: 'overall', label: 'Overall' },
];

function RatingsSection(props: {
  stop: Stop; detail: Detail | null; busy: boolean; signedIn: boolean; onNeedSignIn: () => void;
  onRate: (s: { clean: number; safety: number; supplies: number; overall: number }, review: string) => void;
  onFlag: (ratingId: string, reason: string) => void;
}) {
  const { stop, detail } = props;
  const mine = detail?.myRating;
  const [scores, setScores] = useState({ clean: 0, safety: 0, supplies: 0, overall: 0 });
  const [review, setReview] = useState('');
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    if (mine) {
      setScores({ clean: mine.clean, safety: mine.safety, supplies: mine.supplies, overall: mine.overall });
      setReview(mine.review ?? '');
    } else {
      setScores({ clean: 0, safety: 0, supplies: 0, overall: 0 });
      setReview('');
    }
  }, [mine?.id, mine?.updated_at]);

  const avgs = { clean: stop.avg_clean, safety: stop.avg_safety, supplies: stop.avg_supplies, overall: stop.avg_overall };
  const complete = Object.values(scores).every((v) => v > 0);
  const showForm = editing || (!mine && props.signedIn);

  return (
    <>
      <Section title={`Ratings (${stop.rating_count})`}>
        {SCORE_LABELS.map((l) => (
          <View key={l.key} style={[s.row, { justifyContent: 'space-between' }]}>
            <Text style={{ color: C.ink2, width: 130, fontWeight: l.key === 'overall' ? '800' : '500' }}>{l.label}</Text>
            <View style={{ flex: 1, height: 8, borderRadius: 4, backgroundColor: C.bg, overflow: 'hidden' }}>
              <View style={{ width: `${((avgs[l.key] ?? 0) / 5) * 100}%`, height: 8, backgroundColor: C.amber }} />
            </View>
            <Text style={{ width: 34, textAlign: 'right', fontWeight: '800', color: C.ink }}>{fmtScore(avgs[l.key])}</Text>
          </View>
        ))}

        <View style={{ height: 1, backgroundColor: C.line }} />
        {!props.signedIn ? (
          <Btn kind="ghost" label="Sign in to rate this stop" onPress={props.onNeedSignIn} />
        ) : showForm ? (
          <View style={{ gap: 10 }}>
            <Text style={s.label}>{mine ? 'Edit your rating' : 'Your rating – four quick scores'}</Text>
            {SCORE_LABELS.map((l) => (
              <View key={l.key} style={[s.row, { justifyContent: 'space-between' }]}>
                <Text style={{ color: C.ink2 }}>{l.label}</Text>
                <Stars value={scores[l.key]} onChange={(v) => setScores({ ...scores, [l.key]: v })} />
              </View>
            ))}
            <TextInput
              placeholder="Short review (optional)" placeholderTextColor="#94a3b8" multiline maxLength={1000}
              value={review} onChangeText={setReview} style={[s.input, { minHeight: 64, textAlignVertical: 'top' }]}
            />
            <View style={s.row}>
              <Btn label={mine ? 'Update rating' : 'Post rating'} disabled={!complete} busy={props.busy}
                onPress={() => { props.onRate(scores, review); setEditing(false); }} />
              {editing ? <Btn kind="quiet" label="Cancel" onPress={() => setEditing(false)} /> : null}
            </View>
          </View>
        ) : (
          <View style={[s.row, { justifyContent: 'space-between' }]}>
            <Text style={{ color: C.ink2 }}>You rated this stop ★ {mine?.overall}</Text>
            <Btn small kind="ghost" label="Edit my rating" onPress={() => setEditing(true)} />
          </View>
        )}
      </Section>

      <Section title="Reviews · newest first">
        {detail && !detail.ratings.some((r) => r.review) ? <Text style={s.muted}>No written reviews yet.</Text> : null}
        {detail?.ratings.filter((r) => r.review).map((r) => (
          <View key={r.id} style={{ gap: 4, paddingBottom: 10, borderBottomWidth: 1, borderBottomColor: C.line }}>
            <View style={[s.row, { justifyContent: 'space-between' }]}>
              <Text style={{ fontWeight: '700', color: C.ink }}>{r.author}  <Text style={{ color: C.amber }}>{'★'.repeat(r.overall)}</Text></Text>
              <Text style={s.muted}>{ago(r.updated_at)}{r.updated_at !== r.created_at ? ' · edited' : ''}</Text>
            </View>
            <Text style={{ color: C.ink2, lineHeight: 20 }}>{r.review}</Text>
            <Pressable onPress={() => props.onFlag(r.id, 'Review flagged')} hitSlop={6}>
              <Text style={{ fontSize: 12, color: C.mute }}>⚑ Flag review</Text>
            </Pressable>
          </View>
        ))}
      </Section>
    </>
  );
}

function FuelSection({ stop, busy, onPrice }: { stop: Stop; busy: boolean; onPrice: (g: Grade, p: number) => void }) {
  const [grade, setGrade] = useState<Grade>(stop.diesel === 'yes' && stop.gas !== 'yes' ? 'diesel' : 'regular');
  const [value, setValue] = useState('');
  const price = Number(value.replace(',', '.'));
  const valid = price > 0.5 && price < 15;
  return (
    <Section title="Fuel prices">
      {GRADES.map((g) => {
        const f = stop.fuel[g.key];
        return (
          <View key={g.key} style={[s.row, { justifyContent: 'space-between' }]}>
            <Text style={{ color: C.ink2, width: 90 }}>{g.label}</Text>
            {f ? (
              <>
                <Text style={{ fontSize: 17, fontWeight: '800', color: isPriceStale(f.at) ? C.mute : C.ink }}>{fmtPrice(f.price)}</Text>
                <View style={{ flex: 1, alignItems: 'flex-end' }}>
                  {isPriceStale(f.at) ? <Badge text={`Stale · ${ago(f.at)}`} tone="amber" /> : <Text style={s.muted}>{ago(f.at)}</Text>}
                </View>
              </>
            ) : <Text style={s.muted}>no price yet</Text>}
          </View>
        );
      })}
      <View style={{ height: 1, backgroundColor: C.line }} />
      <Text style={s.label}>Saw the pump? Post a price</Text>
      <View style={[s.row, { flexWrap: 'wrap' }]}>
        {GRADES.map((g) => <Chip key={g.key} label={g.label} on={grade === g.key} onPress={() => setGrade(g.key)} />)}
      </View>
      <View style={s.row}>
        <TextInput value={value} onChangeText={setValue} placeholder="3.49" keyboardType="decimal-pad" inputMode="decimal"
          placeholderTextColor="#94a3b8" style={[s.input, { flex: 1 }]} />
        <Btn label="Post" disabled={!valid} busy={busy} onPress={() => { onPrice(grade, Math.round(price * 1000) / 1000); setValue(''); }} />
      </View>
    </Section>
  );
}

const triLabel = (v: Tri) => (v === 'yes' ? 'Yes' : v === 'no' ? 'No' : 'Unknown');

function AmenitiesSection({ stop, busy, onSave }: { stop: Stop; busy: boolean; onSave: (v: Record<string, string>) => void }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const val = (k: AmenityKey) => (draft[k] as Tri) ?? stop[k];

  return (
    <Section title="What's here" right={editing ? null : <Btn small kind="ghost" label="Update details" onPress={() => { setDraft({}); setEditing(true); }} />}>
      {AMENITY_GROUPS.map((g) => (
        <View key={g.id} style={{ gap: 6 }}>
          <Text style={{ fontWeight: '800', color: C.ink, fontSize: 14 }}>{g.title}</Text>
          {editing ? g.items.map((i) => (
            <View key={i.key} style={[s.row, { justifyContent: 'space-between' }]}>
              <Text style={{ color: C.ink2 }}>{i.label}</Text>
              <TriToggle value={val(i.key)} onChange={(v) => setDraft({ ...draft, [i.key]: v })} />
            </View>
          )) : (
            <View style={[s.row, { flexWrap: 'wrap', gap: 6 }]}>
              {g.items.map((i) => (
                <Badge key={i.key} text={`${stop[i.key] === 'yes' ? '✓' : stop[i.key] === 'no' ? '✕' : '?'} ${i.label}`}
                  tone={stop[i.key] === 'yes' ? 'green' : 'mute'} />
              ))}
            </View>
          )}
          {g.id === 'F5.7' && (editing || stop.rv_dump === 'yes' || stop.potable_note || stop.rv_note) ? (
            <RvDetails stop={stop} editing={editing} draft={draft} setDraft={setDraft} />
          ) : null}
        </View>
      ))}
      {editing ? (
        <View style={s.row}>
          <Btn label="Save details" busy={busy} disabled={!Object.keys(draft).length} onPress={() => { onSave(draft); setEditing(false); }} />
          <Btn kind="quiet" label="Cancel" onPress={() => setEditing(false)} />
        </View>
      ) : <Text style={[s.muted, { fontSize: 12 }]}>Each item is yes, no or unknown. Anyone signed in can correct them.</Text>}
    </Section>
  );
}

function RvDetails({ stop, editing, draft, setDraft }: {
  stop: Stop; editing: boolean; draft: Record<string, string>; setDraft: (d: Record<string, string>) => void;
}) {
  const fee = (draft.dump_fee ?? stop.dump_fee ?? '') as string;
  if (!editing) {
    return (
      <View style={{ backgroundColor: C.bg, borderRadius: 10, padding: 10, gap: 3 }}>
        {stop.rv_dump === 'yes' ? (
          <Text style={{ color: C.ink2 }}>Dump fee: <Text style={{ fontWeight: '700' }}>
            {stop.dump_fee === 'paid' ? `Paid${stop.dump_fee_amount ? ` · $${stop.dump_fee_amount}` : ''}` : stop.dump_fee === 'free' ? 'Free' : 'Unknown'}
          </Text> · Rinse hose: {triLabel(stop.rinse_hose)}</Text>
        ) : null}
        {stop.potable_note ? <Text style={{ color: C.ink2 }}>Water fill: {stop.potable_note}</Text> : null}
        {stop.rv_note ? <Text style={{ color: C.ink2 }}>RV access: {stop.rv_note}</Text> : null}
        <Text style={[s.muted, { fontSize: 11 }]}>Verified with the rest of the stop · {ago(stop.last_verified_at)}</Text>
      </View>
    );
  }
  return (
    <View style={{ gap: 8, backgroundColor: C.bg, padding: 10, borderRadius: 10 }}>
      <Text style={s.label}>Dump fee</Text>
      <View style={s.row}>
        {[['free', 'Free'], ['paid', 'Paid'], ['', 'Unknown']].map(([k, l]) => (
          <Chip key={k} label={l} on={fee === k} onPress={() => setDraft({ ...draft, dump_fee: k })} />
        ))}
      </View>
      {fee === 'paid' ? (
        <Field placeholder="Amount, e.g. 10" keyboardType="decimal-pad" value={draft.dump_fee_amount ?? (stop.dump_fee_amount?.toString() ?? '')}
          onChangeText={(t) => setDraft({ ...draft, dump_fee_amount: t })} />
      ) : null}
      <Field label="Water fill note (hose / spigot type)" value={draft.potable_note ?? stop.potable_note ?? ''}
        onChangeText={(t) => setDraft({ ...draft, potable_note: t })} />
      <Field label="RV length or access note" value={draft.rv_note ?? stop.rv_note ?? ''}
        onChangeText={(t) => setDraft({ ...draft, rv_note: t })} />
    </View>
  );
}
