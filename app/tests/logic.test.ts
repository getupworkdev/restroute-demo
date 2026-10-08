/// <reference types="node" />
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  NO_FILTERS, applyFilters, isOutdated, isPriceStale, locateOnLine, openState, parseHighway,
  simplifyLine, sortStops, stopsAlongLine,
} from '../src/logic';
import type { Stop } from '../src/types';

const base = {
  id: 'x', name: 'Test', stop_type: 'rest_area', lat: 34, lng: -84.39, highway: 'I-75', city: null, state: null,
  access: 'free', open_24h: false, hours: null, tz: 'America/New_York', dump_fee: null, dump_fee_amount: null,
  potable_note: null, rv_note: null, avg_clean: null, avg_safety: null, avg_supplies: null, avg_overall: null,
  rating_count: 0, open_issues: [], fuel: {}, photo_count: 0, last_verified_at: new Date().toISOString(),
  created_at: new Date().toISOString(), created_by: null,
} as unknown as Stop;
const stop = (o: Partial<Stop>): Stop => ({ ...base, ...o } as Stop);

// 2026-10-07 is a Wednesday. 14:00Z = 10:00 in New York (EDT).
const WED_10AM_NY = new Date('2026-10-07T14:00:00Z');
const WED_1AM_NY = new Date('2026-10-07T05:00:00Z');

test('open now follows the stop time zone', () => {
  const s = stop({ hours: { wed: [['06:00', '22:00']] } });
  assert.equal(openState(s, WED_10AM_NY).open, true);
  assert.equal(openState(s, WED_1AM_NY).open, false);
  assert.equal(openState(stop({ ...s, tz: 'America/Los_Angeles' }), WED_10AM_NY).open, true); // 07:00 LA
  assert.equal(openState(stop({ open_24h: true }), WED_1AM_NY).label, 'Open 24/7');
});

test('hours past midnight carry into the next day', () => {
  const s = stop({ hours: { tue: [['18:00', '02:00']] } });
  assert.equal(openState(s, WED_1AM_NY).open, true);
  assert.equal(openState(s, WED_10AM_NY).open, false);
});

test('filters combine with AND and closed stops are hidden by default', () => {
  const stops = [
    stop({ id: 'a', showers: 'yes', diesel: 'yes', avg_overall: 4.5 } as Partial<Stop>),
    stop({ id: 'b', showers: 'yes', diesel: 'no', avg_overall: 4.8 } as Partial<Stop>),
    stop({ id: 'c', showers: 'yes', diesel: 'yes', avg_overall: 2 } as Partial<Stop>),
    stop({ id: 'd', showers: 'yes', diesel: 'yes', avg_overall: 5, open_issues: ['closed'] } as Partial<Stop>),
  ];
  const f = { ...NO_FILTERS, amenities: ['showers', 'diesel'] as const, minRating: 4 };
  assert.deepEqual(applyFilters(stops, f as never).map((s) => s.id), ['a']);
  assert.deepEqual(applyFilters(stops, { ...f, includeClosed: true } as never).map((s) => s.id), ['a', 'd']);
  assert.equal(applyFilters(stops, NO_FILTERS).length, 3);
});

test('freshness: 90-day stamp, 7-day prices', () => {
  const now = new Date('2026-10-08T00:00:00Z');
  assert.equal(isOutdated({ last_verified_at: '2026-07-01T00:00:00Z' }, now), true);
  assert.equal(isOutdated({ last_verified_at: '2026-09-01T00:00:00Z' }, now), false);
  assert.equal(isPriceStale('2026-09-29T00:00:00Z', now), true);
  assert.equal(isPriceStale('2026-10-05T00:00:00Z', now), false);
});

test('sort by price puts stops without that grade last', () => {
  const stops = [
    stop({ id: 'a', fuel: { diesel: { price: 3.9, at: '' } } }),
    stop({ id: 'b', fuel: {} }),
    stop({ id: 'c', fuel: { diesel: { price: 3.7, at: '' } } }),
  ];
  assert.deepEqual(sortStops(stops, 'price:diesel', () => 0).map((s) => s.id), ['c', 'a', 'b']);
});

test('highway search parsing', () => {
  assert.equal(parseHighway('i75'), 'I-75');
  assert.equal(parseHighway('I-75 NB'), 'I-75');
  assert.equal(parseHighway('interstate 10'), 'I-10');
  assert.equal(parseHighway('US 1'), 'US-1');
  assert.equal(parseHighway('Atlanta'), null);
});

test('route: ordered by distance along the route, not straight line', () => {
  // A U-shaped route: north, east, then back south. The stop at the end is close in a
  // straight line to the start but far along the route.
  const line: [number, number][] = [[-84.4, 34.0], [-84.4, 34.5], [-84.3, 34.5], [-84.3, 34.0]];
  const stops = [
    stop({ id: 'end', lat: 34.01, lng: -84.3005 }),
    stop({ id: 'mid', lat: 34.5005, lng: -84.35 }),
    stop({ id: 'start', lat: 34.1, lng: -84.4005 }),
    stop({ id: 'far', lat: 34.2, lng: -84.2 }),
  ];
  const hits = stopsAlongLine(stops, line, 1600);
  assert.deepEqual(hits.map((h) => h.id), ['start', 'mid', 'end']);
  const { along } = locateOnLine(line, { lat: 34.5, lng: -84.4 });
  assert.ok(Math.abs(along - 55660) < 200, String(along));
});

test('simplify keeps the shape and drops redundant points', () => {
  const line: [number, number][] = Array.from({ length: 200 }, (_, i) => [-84 + i * 0.001, 34]);
  line.push([-83.8, 34.1]);
  const s = simplifyLine(line, 30);
  assert.ok(s.length <= 4, String(s.length));
  assert.deepEqual(s.at(-1), [-83.8, 34.1]);
});
