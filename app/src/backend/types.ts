import type {
  AmenityKey, Detail, Flag, Grade, Issue, LngLat, NewStop, RouteHit, Scores, Session, Stop, Tri,
} from '../types';

export type PhotoInput = { uri: string; mimeType?: string | null; file?: Blob | null };

// Everything the screens need from the data layer. Two implementations:
// SupabaseBackend (shared, live across devices) and SampleBackend (in this browser only).
export interface Backend {
  readonly mode: 'shared' | 'sample';

  session(): Session | null;
  onSession(cb: (s: Session | null) => void): () => void;
  signInGuest(displayName: string): Promise<void>;
  signOut(): Promise<void>;

  loadStops(): Promise<Stop[]>;
  getStop(id: string): Promise<Stop | null>;
  // Fires when any stop changes on any device: added, re-rated, reported, verified.
  onStopChanged(cb: (stop: Stop | { id: string; removed: true }) => void): () => void;

  getDetail(id: string): Promise<Detail>;
  onDetailChanged(id: string, cb: () => void): () => void;

  addStop(input: NewStop, photo: PhotoInput | null): Promise<Stop>;
  rate(locationId: string, scores: Scores, review: string): Promise<void>;
  report(locationId: string, issue: Issue, note: string): Promise<void>;
  verify(locationId: string): Promise<void>;
  addPrice(locationId: string, grade: Grade, price: number): Promise<void>;
  setAmenities(locationId: string, values: Partial<Record<AmenityKey, Tri>> & Record<string, string>): Promise<void>;
  addPhoto(locationId: string, photo: PhotoInput): Promise<void>;
  setFavorite(locationId: string, on: boolean): Promise<void>;
  favorites(): Promise<string[]>;
  flag(target: { type: 'location' | 'rating' | 'photo'; id: string; locationId: string }, reason: string): Promise<void>;

  stopsAlongRoute(line: LngLat[], corridorM: number): Promise<RouteHit[]>;

  moderationQueue(): Promise<Flag[]>;
  moderate(flagId: string, action: 'dismiss' | 'remove' | 'restore'): Promise<void>;
}

export class SignInRequired extends Error {
  constructor() {
    super('Sign in to contribute');
  }
}
