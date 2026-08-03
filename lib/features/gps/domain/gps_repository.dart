import 'gps_sample.dart';

/// Abstraction over the platform location provider. The dashboard/trip layers
/// depend on this, never on geolocator directly — so the GPS engine can be
/// swapped (mock, replay-from-GPX, alternate plugin) without touching UI.
abstract class GpsRepository {
  /// Ensure location services are enabled and permission granted.
  /// Returns true when streaming is possible.
  Future<bool> ensurePermission();

  /// Continuous stream of fixes. Emits a [GpsSample.noFix] style sample on
  /// dropout so consumers can react instead of silently freezing.
  Stream<GpsSample> positionStream();

  /// One-shot best current fix (used to seed the map before streaming).
  Future<GpsSample?> lastKnown();
}
