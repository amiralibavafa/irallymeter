// C3 — the cold-start seed fix used the provider the rest of the file refuses.
//
// The position STREAM sets `forceLocationManager: true` on purpose: the fused
// provider road-snaps, and a rally trip computer measuring distance must not be
// handed positions that have been moved onto the nearest road.
// `platform_settings_test.dart` already pins that.
//
// `lastKnown()` called `Geolocator.getLastKnownPosition()` with NO arguments.
// That parameter defaults to FALSE, and the plugin's GeolocationManager then
// returns FusedLocationClient whenever Google Play Services is present — which
// is most real phones. So the FIRST position the map and the speedometer showed
// came from exactly the provider the stream avoids.
//
// A seed fix snapped to a road is worse than a slightly stale raw one: it is
// confidently wrong, and it is what the trip anchor starts from.
//
// Not caught by any existing test because it is an argument default, invisible
// at the call site. That is also why it is now behind a seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:irallymeter/features/gps/data/geolocator_gps_service.dart';

void main() {
  group('C3 · cold-start seed fix', () {
    test('01 · lastKnown() FORCES the LocationManager provider', () async {
      // THE REGRESSION. Before the fix this recorded `false`, meaning the fused
      // road-snapping provider on any device with Play Services.
      bool? forced;
      final svc = GeolocatorGpsService(
        lastKnownSource: ({required bool forceAndroidLocationManager}) async {
          forced = forceAndroidLocationManager;
          return _pos();
        },
      );

      await svc.lastKnown();

      expect(forced, isTrue,
          reason: 'the seed fix came from FusedLocationClient, which snaps to '
              'the nearest road. The stream sets forceLocationManager: true to '
              'avoid exactly that, so the two disagreed and the disagreement '
              'was invisible — it lived in an argument default');
    });

    test('02 · a null last-known is passed through, not invented', () async {
      // A cold device with no cached fix must yield null so the map waits,
      // rather than seeding the trip anchor from something made up.
      final svc = GeolocatorGpsService(
        lastKnownSource: ({required bool forceAndroidLocationManager}) async =>
            null,
      );

      expect(await svc.lastKnown(), isNull);
    });

    test('03 · the fix is converted without sanitising the raw speed',
        () async {
      // §7.1 needs to SEE an unusable Doppler reading to fall back to
      // differentiating positions, so the seed must not coerce it.
      final svc = GeolocatorGpsService(
        lastKnownSource: ({required bool forceAndroidLocationManager}) async =>
            _pos(speed: -1),
      );

      final s = await svc.lastKnown();
      expect(s, isNotNull);
      expect(s!.speedMps, -1,
          reason: 'a negative Doppler reading was coerced, which makes it '
              'indistinguishable from a genuine standstill downstream');
    });
  });
}

Position _pos({double speed = 12}) => Position(
      latitude: 35.7745,
      longitude: 51.386,
      timestamp: DateTime.utc(2026),
      accuracy: 8,
      altitude: 1200,
      altitudeAccuracy: 3,
      heading: 90,
      headingAccuracy: 5,
      speed: speed,
      speedAccuracy: 0.5,
    );
