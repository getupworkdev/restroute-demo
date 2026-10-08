// Web map: MapLibre GL with OpenFreeMap tiles. Pins cluster at low zoom (F2.1).
import * as maplibregl from 'maplibre-gl';
import type { GeoJSONSource, Map as MLMap } from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useEffect, useRef } from 'react';
import { View } from 'react-native';
import { isOutdated, isReportedClosed } from '../logic';
import { STOP_TYPES } from '../meta';
import type { Stop } from '../types';
import type { MapProps } from './types';

const STYLE = 'https://tiles.openfreemap.org/styles/liberty';
const typeColor: unknown[] = ['match', ['get', 'type']];
for (const t of STOP_TYPES) typeColor.push(t.key, t.color);
typeColor.push('#475569');

function toGeoJSON(stops: Stop[], selectedId: string | null) {
  return {
    type: 'FeatureCollection' as const,
    features: stops.map((s) => ({
      type: 'Feature' as const,
      geometry: { type: 'Point' as const, coordinates: [s.lng, s.lat] },
      properties: {
        id: s.id, type: s.stop_type, selected: s.id === selectedId ? 1 : 0,
        closed: isReportedClosed(s) ? 1 : 0, issue: s.open_issues.length ? 1 : 0, stale: isOutdated(s) ? 1 : 0,
      },
    })),
  };
}

export default function StopMap(props: MapProps) {
  const host = useRef<View>(null);
  const map = useRef<MLMap | null>(null);
  const ready = useRef(false);
  const latest = useRef(props);
  latest.current = props;
  const userMarker = useRef<maplibregl.Marker | null>(null);
  const pickMarker = useRef<maplibregl.Marker | null>(null);

  useEffect(() => {
    const el = host.current as unknown as HTMLElement;
    const m = new maplibregl.Map({
      container: el, style: STYLE, center: [-90, 34.5], zoom: 4.1, attributionControl: { compact: true },
    });
    map.current = m;
    m.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'bottom-right');
    m.on('load', () => {
      m.addSource('route', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
      m.addLayer({ id: 'route-casing', type: 'line', source: 'route', paint: { 'line-color': '#ffffff', 'line-width': 9, 'line-opacity': 0.9 }, layout: { 'line-cap': 'round', 'line-join': 'round' } });
      m.addLayer({ id: 'route', type: 'line', source: 'route', paint: { 'line-color': '#2563eb', 'line-width': 5 }, layout: { 'line-cap': 'round', 'line-join': 'round' } });

      m.addSource('stops', {
        type: 'geojson', data: toGeoJSON(latest.current.stops, latest.current.selectedId),
        cluster: true, clusterRadius: 46, clusterMaxZoom: 11,
      });
      m.addLayer({
        id: 'clusters', type: 'circle', source: 'stops', filter: ['has', 'point_count'],
        paint: {
          'circle-color': '#0f172a', 'circle-opacity': 0.88, 'circle-stroke-color': '#fbbf24', 'circle-stroke-width': 2,
          'circle-radius': ['step', ['get', 'point_count'], 15, 5, 19, 15, 24],
        },
      });
      m.addLayer({
        id: 'cluster-count', type: 'symbol', source: 'stops', filter: ['has', 'point_count'],
        layout: { 'text-field': ['get', 'point_count_abbreviated'], 'text-font': ['Noto Sans Bold'], 'text-size': 13 },
        paint: { 'text-color': '#ffffff' },
      });
      m.addLayer({
        id: 'stop-halo', type: 'circle', source: 'stops', filter: ['all', ['!', ['has', 'point_count']], ['==', ['get', 'selected'], 1]],
        paint: { 'circle-radius': 17, 'circle-color': '#fbbf24', 'circle-opacity': 0.45 },
      });
      m.addLayer({
        id: 'stops', type: 'circle', source: 'stops', filter: ['!', ['has', 'point_count']],
        paint: {
          'circle-color': ['case', ['==', ['get', 'closed'], 1], '#94a3b8', typeColor as never],
          'circle-radius': ['case', ['==', ['get', 'selected'], 1], 10, 8],
          'circle-stroke-color': ['case', ['==', ['get', 'issue'], 1], '#dc2626', '#ffffff'],
          'circle-stroke-width': ['case', ['==', ['get', 'issue'], 1], 3, 2],
          'circle-opacity': ['case', ['==', ['get', 'stale'], 1], 0.6, 1],
        },
      });

      m.on('click', 'clusters', async (e) => {
        const f = e.features?.[0];
        if (!f) return;
        const src = m.getSource('stops') as GeoJSONSource;
        const zoom = await src.getClusterExpansionZoom(f.properties.cluster_id as number);
        m.easeTo({ center: (f.geometry as GeoJSON.Point).coordinates as [number, number], zoom: zoom + 0.3 });
      });
      m.on('click', 'stops', (e) => {
        const f = e.features?.[0];
        if (f) latest.current.onSelect(f.properties.id as string);
      });
      m.on('click', (e) => {
        const hits = m.queryRenderedFeatures(e.point, { layers: ['stops', 'clusters'] });
        if (hits.length) return;
        if (latest.current.pick) latest.current.onPick(e.lngLat.lat, e.lngLat.lng);
        else latest.current.onSelect(null);
      });
      for (const l of ['clusters', 'stops']) {
        m.on('mouseenter', l, () => { m.getCanvas().style.cursor = 'pointer'; });
        m.on('mouseleave', l, () => { m.getCanvas().style.cursor = ''; });
      }
      m.on('moveend', () => {
        const c = m.getCenter();
        latest.current.onCenterChange?.({ lat: c.lat, lng: c.lng });
      });
      ready.current = true;
      sync();
    });
    const ro = new ResizeObserver(() => m.resize());
    ro.observe(el);
    return () => { ro.disconnect(); m.remove(); map.current = null; ready.current = false; };
  }, []);

  function sync() {
    const m = map.current;
    if (!m || !ready.current) return;
    const p = latest.current;
    (m.getSource('stops') as GeoJSONSource).setData(toGeoJSON(p.stops, p.selectedId));
    (m.getSource('route') as GeoJSONSource).setData(p.route
      ? { type: 'Feature', geometry: { type: 'LineString', coordinates: p.route }, properties: {} }
      : { type: 'FeatureCollection', features: [] });
  }
  useEffect(sync, [props.stops, props.selectedId, props.route]);

  useEffect(() => {
    const m = map.current;
    if (!m) return;
    userMarker.current?.remove();
    userMarker.current = null;
    if (props.user) {
      const dot = document.createElement('div');
      dot.style.cssText = 'width:16px;height:16px;border-radius:50%;background:#2563eb;border:3px solid #fff;box-shadow:0 0 0 6px rgba(37,99,235,.25)';
      userMarker.current = new maplibregl.Marker({ element: dot }).setLngLat([props.user.lng, props.user.lat]).addTo(m);
    }
  }, [props.user?.lat, props.user?.lng]);

  useEffect(() => {
    const m = map.current;
    if (!m) return;
    if (!props.pick) {
      pickMarker.current?.remove();
      pickMarker.current = null;
      return;
    }
    if (!pickMarker.current) {
      pickMarker.current = new maplibregl.Marker({ color: '#dc2626', draggable: true })
        .setLngLat([props.pick.lng, props.pick.lat]).addTo(m);
      pickMarker.current.on('dragend', () => {
        const ll = pickMarker.current!.getLngLat();
        latest.current.onPick(ll.lat, ll.lng);
      });
    } else {
      pickMarker.current.setLngLat([props.pick.lng, props.pick.lat]);
    }
  }, [props.pick?.lat, props.pick?.lng, !!props.pick]);

  useEffect(() => {
    const m = map.current;
    const f = props.focus;
    if (!m || !f) return;
    const go = () => {
      if (f.kind === 'point') m.flyTo({ center: [f.lng, f.lat], zoom: f.zoom ?? Math.max(m.getZoom(), 9), duration: 900 });
      else if (f.points.length) {
        const b = new maplibregl.LngLatBounds(f.points[0], f.points[0]);
        f.points.forEach((p) => b.extend(p));
        m.fitBounds(b, { padding: 60, duration: 900, maxZoom: 12 });
      }
    };
    if (ready.current) go(); else m.once('load', go);
  }, [props.focus?.n]);

  return <View ref={host} style={{ flex: 1, minHeight: 200 }} />;
}
