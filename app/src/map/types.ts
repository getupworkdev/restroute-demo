import type { LngLat, Stop } from '../types';

export type Focus =
  | { kind: 'point'; lat: number; lng: number; zoom?: number; n: number }
  | { kind: 'bounds'; points: LngLat[]; n: number };

export type MapProps = {
  stops: Stop[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  user: { lat: number; lng: number } | null;
  route: LngLat[] | null;
  focus: Focus | null;
  // Add-a-stop mode (F3.2): a draggable pin; tapping the map also moves it.
  pick: { lat: number; lng: number } | null;
  onPick: (lat: number, lng: number) => void;
  onCenterChange?: (c: { lat: number; lng: number }) => void;
};
