// iOS / Android map: react-native-maps (Apple Maps on iOS, Google Maps on Android).
// The web build uses StopMap.web.tsx (MapLibre) instead.
import { useEffect, useRef } from 'react';
import MapView, { Marker, Polyline } from 'react-native-maps';
import { isReportedClosed } from '../logic';
import { TYPE_COLOR } from '../meta';
import type { MapProps } from './types';

export default function StopMap(props: MapProps) {
  const ref = useRef<MapView>(null);

  useEffect(() => {
    const f = props.focus;
    if (!f || !ref.current) return;
    if (f.kind === 'point') {
      ref.current.animateToRegion({ latitude: f.lat, longitude: f.lng, latitudeDelta: 0.6, longitudeDelta: 0.6 }, 700);
    } else if (f.points.length) {
      ref.current.fitToCoordinates(f.points.map(([lng, lat]) => ({ latitude: lat, longitude: lng })), {
        edgePadding: { top: 60, right: 60, bottom: 60, left: 60 }, animated: true,
      });
    }
  }, [props.focus?.n]);

  return (
    <MapView
      ref={ref}
      style={{ flex: 1 }}
      initialRegion={{ latitude: 34.5, longitude: -90, latitudeDelta: 25, longitudeDelta: 35 }}
      showsUserLocation={!!props.user}
      onPress={(e) => {
        if (props.pick) props.onPick(e.nativeEvent.coordinate.latitude, e.nativeEvent.coordinate.longitude);
        else props.onSelect(null);
      }}
      onRegionChangeComplete={(r) => props.onCenterChange?.({ lat: r.latitude, lng: r.longitude })}
    >
      {props.route && (
        <Polyline coordinates={props.route.map(([lng, lat]) => ({ latitude: lat, longitude: lng }))} strokeColor="#2563eb" strokeWidth={5} />
      )}
      {props.stops.map((s) => (
        <Marker
          key={s.id}
          coordinate={{ latitude: s.lat, longitude: s.lng }}
          pinColor={isReportedClosed(s) ? '#94a3b8' : TYPE_COLOR[s.stop_type]}
          onPress={(e) => { e.stopPropagation(); props.onSelect(s.id); }}
          tracksViewChanges={false}
        />
      ))}
      {props.pick && (
        <Marker
          draggable
          coordinate={{ latitude: props.pick.lat, longitude: props.pick.lng }}
          pinColor="#dc2626"
          onDragEnd={(e) => props.onPick(e.nativeEvent.coordinate.latitude, e.nativeEvent.coordinate.longitude)}
        />
      )}
    </MapView>
  );
}
