import { SampleBackend } from './sample';
import { SupabaseBackend } from './supabase';
import type { Backend } from './types';

export * from './types';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
const key = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;

// With Supabase keys the app is shared and live; without them it runs on sample data.
export const backend: Backend = url && key ? new SupabaseBackend(url, key) : new SampleBackend();
