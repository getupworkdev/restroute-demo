// External lookups: city search (Photon / OpenStreetMap), driving routes (OSRM), device GPS.
import * as Location from 'expo-location';
import type { LngLat } from './types';

export type Place = { name: string; detail: string; lat: number; lng: number };

export async function searchPlaces(q: string): Promise<Place[]> {
  const url = `https://photon.komoot.io/api/?q=${encodeURIComponent(q)}&limit=6&lang=en&bbox=-125,24,-66,50`;
  const res = await fetch(url);
  if (!res.ok) throw new Error('Place search is unavailable right now');
  const data = (await res.json()) as {
    features: { geometry: { coordinates: [number, number] }; properties: Record<string, string> }[];
  };
  return data.features.map((f) => {
    const p = f.properties;
    return {
      name: p.name ?? p.city ?? q,
      detail: [p.city !== p.name ? p.city : null, p.state, p.country].filter(Boolean).join(', '),
      lat: f.geometry.coordinates[1],
      lng: f.geometry.coordinates[0],
    };
  });
}

export async function drivingRoute(from: { lat: number; lng: number }, to: { lat: number; lng: number }) {
  const url = `https://router.project-osrm.org/route/v1/driving/${from.lng},${from.lat};${to.lng},${to.lat}?overview=full&geometries=geojson`;
  const res = await fetch(url);
  if (!res.ok) throw new Error('Routing is unavailable right now');
  const data = (await res.json()) as { routes?: { distance: number; duration: number; geometry: { coordinates: LngLat[] } }[] };
  const r = data.routes?.[0];
  if (!r) throw new Error('No driving route found');
  return { line: r.geometry.coordinates, distance: r.distance, duration: r.duration };
}

export async function myPosition(): Promise<{ lat: number; lng: number }> {
  const perm = await Location.requestForegroundPermissionsAsync();
  if (perm.status !== 'granted') throw new Error('Location permission was not given');
  const p = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
  return { lat: p.coords.latitude, lng: p.coords.longitude };
}

// Time zone for a new stop: the device's own zone is the right guess when tagging on site.
export const deviceTimeZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York';
