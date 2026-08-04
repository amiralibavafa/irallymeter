import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:irallymeter/core/constants/app_constants.dart';
import 'package:irallymeter/features/gps/data/geolocator_gps_service.dart';

/// SPEC-v2 §18.2 — the receiver configuration, expressed in Dart.
///
/// These tests exist because the bug they lock out was INVISIBLE. `_settings()`
/// returned `AndroidSettings` on every platform; since `AndroidSettings` is a
/// `LocationSettings`, it compiled, ran, and quietly gave iOS none of the five
/// options §18.2 names. Nothing failed — the app just measured worse on iOS
/// than anyone realised. A type-level mistake needs a type-level test.
void main() {
  final service = GeolocatorGpsService();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  LocationSettings on(TargetPlatform p, {bool background = true}) {
    debugDefaultTargetPlatformOverride = p;
    return service.buildSettings(background: background);
  }

  group('§18.2 · iOS', () {
    test('01 · iOS gets AppleSettings, not AndroidSettings', () {
      expect(on(TargetPlatform.iOS), isA<AppleSettings>());
    });

    test('02 · macOS gets AppleSettings too', () {
      expect(on(TargetPlatform.macOS), isA<AppleSettings>());
    });

    test('03 · all five §18.2 iOS options are set', () {
      final s = on(TargetPlatform.iOS) as AppleSettings;
      expect(s.activityType, ActivityType.automotiveNavigation);
      expect(s.accuracy, LocationAccuracy.bestForNavigation);
      expect(s.allowBackgroundLocationUpdates, isTrue);
      expect(s.pauseLocationUpdatesAutomatically, isFalse);
      expect(s.showBackgroundLocationIndicator, isTrue);
    });

    test('04 · iOS is never allowed to pause updates at a standstill', () {
      // §18.2: "otherwise iOS will pause updates when it thinks the vehicle has
      // stopped." A rally car sits still at a start line and at a time control.
      // This holds in the foreground-only fallback too, where a paused receiver
      // would be just as wrong.
      for (final bg in [true, false]) {
        final s = on(TargetPlatform.iOS, background: bg) as AppleSettings;
        expect(s.pauseLocationUpdatesAutomatically, isFalse,
            reason: 'background=$bg must not change this');
      }
    });

    test('05 · the foreground-only fallback drops background updates', () {
      // Both flags need "always" permission; asking for them anyway is what
      // makes iOS raise, and raising is what the fallback exists to survive.
      final s = on(TargetPlatform.iOS, background: false) as AppleSettings;
      expect(s.allowBackgroundLocationUpdates, isFalse);
      expect(s.showBackgroundLocationIndicator, isFalse);
    });
  });

  group('§18.2 · Android', () {
    test('06 · Android still gets AndroidSettings', () {
      expect(on(TargetPlatform.android), isA<AndroidSettings>());
    });

    test('07 · the raw LocationManager is used, not fused location', () {
      // §18.2: fused location's "smoothing and road snapping [is] helpful for
      // navigation and wrong for measurement". A snapped fix silently rewrites
      // the distance this app is being paid to measure.
      final s = on(TargetPlatform.android) as AndroidSettings;
      expect(s.forceLocationManager, isTrue);
    });

    test('08 · updates at least as fast as §18.2 asks, and high accuracy', () {
      // §18.2 says "intervalDuration of 1 second". That is a FLOOR for a
      // measurement instrument, not a cap: amir requests 200 ms (5 Hz)
      // deliberately, and a faster fix rate strictly improves every §19 target.
      // So this asserts the direction, not the literal number — an interval
      // SLOWER than the spec's would be the regression worth catching.
      final s = on(TargetPlatform.android) as AndroidSettings;
      expect(s.intervalDuration, AppConstants.gpsInterval);
      expect(AppConstants.gpsInterval,
          lessThanOrEqualTo(const Duration(seconds: 1)));
      expect(s.accuracy, LocationAccuracy.bestForNavigation);
    });

    test('09 · the foreground service is configured in Dart, and droppable',
        () {
      expect(
        (on(TargetPlatform.android) as AndroidSettings)
            .foregroundNotificationConfig,
        isNotNull,
      );
      expect(
        (on(TargetPlatform.android, background: false) as AndroidSettings)
            .foregroundNotificationConfig,
        isNull,
        reason: 'the FGS fails to start when POST_NOTIFICATIONS is denied; the '
            'dashboard has to keep working foreground-only',
      );
    });
  });

  group('§18.2 · every platform', () {
    test('10 · no platform silently falls through to a default', () {
      for (final p in TargetPlatform.values) {
        final s = on(p);
        expect(s.accuracy, LocationAccuracy.bestForNavigation,
            reason: '$p must be configured deliberately, not by inheritance');
        expect(s.distanceFilter, AppConstants.gpsDistanceFilterMeters,
            reason: '$p');
      }
    });

    test('11 · time-based updates: the distance filter never gates a crawl',
        () {
      // A car creeping through a time control still has to be measured.
      expect(AppConstants.gpsDistanceFilterMeters, 0);
    });
  });
}
