/// Where a distance increment came from. Ordered by trust: [gps] is ground
/// truth, [sensor] is an estimate, [manual] is driver-asserted.
enum DistanceSource { gps, sensor, manual }

/// One increment of travel, emitted by the distance engine and folded into the
/// trip computer and the average-speed integrator.
///
/// This is the single currency the consumers speak, which is the whole point of
/// the engine: Trip A/B, the odometer and the average readout no longer know or
/// care whether the metres came from a GPS fix pair, a sensor estimate inside a
/// tunnel, or a post-tunnel correction.
///
/// The [meters]/[dt] split is deliberate and load-bearing:
///  • [meters] is movement to integrate — already gated, so a standstill step
///    arrives as a real delta with `meters == 0` rather than being dropped.
///  • [dt] is travel time this delta represents. It is `Duration.zero` for
///    corrections, which are pure distance with no time of their own — that is
///    what stops a reconciliation from double-counting elapsed time and
///    corrupting the average speed.
///
/// Keeping both in one object is what lets the trip computer (distance only)
/// and the average-speed integrator (distance AND time, with time accruing even
/// while stopped) stay in lockstep off a single event.
class DistanceDelta {
  const DistanceDelta({
    required this.timestamp,
    required this.meters,
    required this.dt,
    required this.speedMps,
    required this.source,
  });

  /// Instant this increment ends at.
  final DateTime timestamp;

  /// Ground distance covered, in metres. Never negative — the engine and every
  /// source guarantee this so a trip counter can never run backwards.
  final double meters;

  /// Travel time this increment represents. Zero for corrections.
  final Duration dt;

  /// Best speed estimate at [timestamp], in m/s.
  final double speedMps;

  final DistanceSource source;

  /// A pure distance correction with no time of its own.
  factory DistanceDelta.correction({
    required DateTime timestamp,
    required double meters,
    required double speedMps,
  }) =>
      DistanceDelta(
        timestamp: timestamp,
        meters: meters,
        dt: Duration.zero,
        speedMps: speedMps,
        source: DistanceSource.gps,
      );

  @override
  String toString() =>
      'DistanceDelta(${meters.toStringAsFixed(2)}m, ${dt.inMilliseconds}ms, '
      '${speedMps.toStringAsFixed(1)}m/s, ${source.name})';
}
