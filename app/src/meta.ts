import type { Access, AmenityKey, Day, Grade, Issue, StopType } from './types';

export const STOP_TYPES: { key: StopType; label: string; color: string }[] = [
  { key: 'rest_area', label: 'Rest area', color: '#1f7a4d' },
  { key: 'gas_station', label: 'Gas station', color: '#c2410c' },
  { key: 'truck_stop', label: 'Truck stop', color: '#7c2d12' },
  { key: 'fast_food', label: 'Fast food', color: '#b45309' },
  { key: 'store', label: 'Store', color: '#6d28d9' },
  { key: 'park', label: 'Park', color: '#15803d' },
  { key: 'public_restroom', label: 'Public restroom', color: '#1d4ed8' },
];
export const TYPE_LABEL = Object.fromEntries(STOP_TYPES.map((t) => [t.key, t.label])) as Record<StopType, string>;
export const TYPE_COLOR = Object.fromEntries(STOP_TYPES.map((t) => [t.key, t.color])) as Record<StopType, string>;

export const ACCESS: { key: Access; label: string }[] = [
  { key: 'free', label: 'Free, open to anyone' },
  { key: 'customers', label: 'Customers only' },
  { key: 'code', label: 'Code or key from staff' },
];

export const ISSUES: { key: Issue; label: string }[] = [
  { key: 'closed', label: 'Closed' },
  { key: 'out_of_order', label: 'Out of order' },
  { key: 'no_supplies', label: 'No toilet paper / soap' },
  { key: 'other', label: 'Other' },
];
export const ISSUE_LABEL = Object.fromEntries(ISSUES.map((i) => [i.key, i.label])) as Record<Issue, string>;

export const GRADES: { key: Grade; label: string }[] = [
  { key: 'regular', label: 'Regular' },
  { key: 'midgrade', label: 'Mid-grade' },
  { key: 'premium', label: 'Premium' },
  { key: 'diesel', label: 'Diesel' },
];

export const DAYS: { key: Day; label: string }[] = [
  { key: 'mon', label: 'Mon' }, { key: 'tue', label: 'Tue' }, { key: 'wed', label: 'Wed' },
  { key: 'thu', label: 'Thu' }, { key: 'fri', label: 'Fri' }, { key: 'sat', label: 'Sat' }, { key: 'sun', label: 'Sun' },
];

// Spec sections F5 and F6, in the order the detail view shows them.
export const AMENITY_GROUPS: { id: string; title: string; items: { key: AmenityKey; label: string }[] }[] = [
  { id: 'F5.1', title: 'Fuel', items: [{ key: 'gas', label: 'Gas' }, { key: 'diesel', label: 'Diesel' }] },
  {
    id: 'F5.2', title: 'Food', items: [
      { key: 'fast_food', label: 'Fast food' }, { key: 'diner', label: 'Diner' },
      { key: 'convenience_store', label: 'Convenience store' }, { key: 'vending', label: 'Vending' },
      { key: 'coffee', label: 'Coffee' },
    ],
  },
  {
    id: 'F5.3', title: 'Parking', items: [
      { key: 'car_parking', label: 'Car' }, { key: 'truck_parking', label: 'Truck' },
      { key: 'rv_parking', label: 'RV / trailer' }, { key: 'overnight_parking', label: 'Overnight allowed' },
    ],
  },
  { id: 'F5.5', title: 'Showers & laundry', items: [{ key: 'showers', label: 'Showers' }, { key: 'laundry', label: 'Laundry' }] },
  {
    id: 'F5.7', title: 'RV services', items: [
      { key: 'rv_dump', label: 'Dump station' }, { key: 'rinse_hose', label: 'Rinse hose' },
      { key: 'potable_water', label: 'Potable water fill' },
    ],
  },
  {
    id: 'F6.1', title: 'Accessibility & family', items: [
      { key: 'wheelchair', label: 'Wheelchair accessible' }, { key: 'baby_changing', label: 'Baby changing' },
      { key: 'family_restroom', label: 'Family / gender-neutral' },
    ],
  },
  {
    id: 'F6.2', title: 'Conveniences', items: [
      { key: 'pet_area', label: 'Pet relief area' }, { key: 'bottle_refill', label: 'Water bottle refill' },
      { key: 'wifi', label: 'Wi-Fi' }, { key: 'ev_charging', label: 'EV charging' },
      { key: 'picnic', label: 'Picnic area' }, { key: 'atm', label: 'ATM' },
    ],
  },
];
export const AMENITY_LABEL = Object.fromEntries(
  AMENITY_GROUPS.flatMap((g) => g.items.map((i) => [i.key, i.label]))
) as Record<AmenityKey, string>;
export const AMENITY_KEYS = AMENITY_GROUPS.flatMap((g) => g.items.map((i) => i.key));

// Quick amenity filters shown as chips (F2.4); the full list is in the filter panel.
export const QUICK_AMENITIES: AmenityKey[] = ['showers', 'diesel', 'ev_charging', 'truck_parking', 'rv_dump', 'baby_changing'];

export const STALE_DAYS = 90;        // F4.4 "information may be outdated"
export const PRICE_STALE_DAYS = 7;   // F5.6 stale fuel price
export const ROUTE_CORRIDOR_M = 1600;
