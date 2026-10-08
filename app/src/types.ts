export type StopType =
  | 'rest_area' | 'gas_station' | 'truck_stop' | 'fast_food' | 'store' | 'park' | 'public_restroom';
export type Access = 'free' | 'customers' | 'code';
export type Tri = 'yes' | 'no' | 'unknown';
export type Issue = 'closed' | 'out_of_order' | 'no_supplies' | 'other';
export type Grade = 'regular' | 'midgrade' | 'premium' | 'diesel';
export type Day = 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat' | 'sun';
export type Hours = Partial<Record<Day, [string, string][]>>;

export type AmenityKey =
  | 'gas' | 'diesel' | 'fast_food' | 'diner' | 'convenience_store' | 'vending' | 'coffee'
  | 'car_parking' | 'truck_parking' | 'rv_parking' | 'overnight_parking' | 'showers' | 'laundry'
  | 'rv_dump' | 'rinse_hose' | 'potable_water'
  | 'wheelchair' | 'baby_changing' | 'family_restroom' | 'pet_area' | 'bottle_refill' | 'wifi'
  | 'ev_charging' | 'picnic' | 'atm';

export type Stop = {
  id: string;
  name: string;
  stop_type: StopType;
  lat: number;
  lng: number;
  highway: string | null;
  city: string | null;
  state: string | null;
  access: Access;
  open_24h: boolean;
  hours: Hours | null;
  tz: string;
  dump_fee: 'free' | 'paid' | null;
  dump_fee_amount: number | null;
  potable_note: string | null;
  rv_note: string | null;
  avg_clean: number | null;
  avg_safety: number | null;
  avg_supplies: number | null;
  avg_overall: number | null;
  rating_count: number;
  open_issues: Issue[];
  fuel: Partial<Record<Grade, { price: number; at: string }>>;
  photo_count: number;
  last_verified_at: string;
  created_at: string;
  created_by: string | null;
} & Record<AmenityKey, Tri>;

export type Rating = {
  id: string;
  location_id: string;
  user_id: string;
  author: string;
  clean: number;
  safety: number;
  supplies: number;
  overall: number;
  review: string | null;
  created_at: string;
  updated_at: string;
};

export type Report = {
  id: string;
  location_id: string;
  user_id: string;
  issue: Issue;
  note: string | null;
  status: 'open' | 'resolved';
  created_at: string;
};

export type Photo = { id: string; location_id: string; url: string; created_at: string };

export type FuelPrice = { grade: Grade; price: number; reported_at: string };

export type Flag = {
  id: string;
  target_type: 'location' | 'rating' | 'photo';
  target_id: string;
  location_id: string | null;
  location_name: string | null;
  reason: string;
  status: 'pending' | 'actioned' | 'dismissed';
  created_at: string;
};

export type Session = { userId: string; displayName: string; isAdmin: boolean };

export type Detail = {
  ratings: Rating[];
  reports: Report[];
  photos: Photo[];
  priceHistory: FuelPrice[];
  myRating: Rating | null;
  favorite: boolean;
};

export type NewStop = {
  name: string;
  stop_type: StopType;
  lat: number;
  lng: number;
  highway: string;
  access: Access;
  open_24h: boolean;
  hours: Hours | null;
  tz: string;
  amenities: Partial<Record<AmenityKey, Tri>>;
};

export type Scores = { clean: number; safety: number; supplies: number; overall: number };

export type LngLat = [number, number];
export type RouteHit = { id: string; along_m: number; off_route_m: number };
