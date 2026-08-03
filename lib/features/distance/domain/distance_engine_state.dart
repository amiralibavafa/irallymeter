import 'distance_delta.dart';

/// Immutable snapshot of what the distance engine is doing right now.
/// Immutable so Riverpod `select` can cheaply diff individual fields, matching
/// the pattern the GPS/trip states already use.
class DistanceEngineState {
  const DistanceEngineState({
    required this.source,
    required this.tunnelMode,
    required this.manualTunnel,
    required this.reconciling,
    required this.speedMps,
    required this.tunnelSince,
    required this.tunnelMeters,
    required this.axisConfidence,
  });

  /// Which source the current distance is coming from.
  final DistanceSource source;

  /// True while GPS is unusable and distance is being estimated from sensors.
  final bool tunnelMode;

  /// True while the driver is recording a manual tunnel.
  final bool manualTunnel;

  /// True while a post-tunnel GPS correction is still being paid out.
  final bool reconciling;

  /// Best current speed estimate (m/s) — GPS when healthy, sensor in a tunnel.
  final double speedMps;

  /// When the current tunnel began (null when not in one).
  final DateTime? tunnelSince;

  /// Distance estimated so far inside the current tunnel (m).
  final double tunnelMeters;

  /// Confidence in the learned forward axis, 0..1. Surfaced for diagnostics:
  /// below [AppConstants.minAxisConfidence] the sensor fallback coasts at the
  /// entry speed rather than tracking acceleration.
  final double axisConfidence;

  /// True whenever distance is NOT coming from live GPS.
  bool get isEstimating => tunnelMode;

  DistanceEngineState copyWith({
    DistanceSource? source,
    bool? tunnelMode,
    bool? manualTunnel,
    bool? reconciling,
    double? speedMps,
    DateTime? tunnelSince,
    bool clearTunnelSince = false,
    double? tunnelMeters,
    double? axisConfidence,
  }) {
    return DistanceEngineState(
      source: source ?? this.source,
      tunnelMode: tunnelMode ?? this.tunnelMode,
      manualTunnel: manualTunnel ?? this.manualTunnel,
      reconciling: reconciling ?? this.reconciling,
      speedMps: speedMps ?? this.speedMps,
      tunnelSince: clearTunnelSince ? null : (tunnelSince ?? this.tunnelSince),
      tunnelMeters: tunnelMeters ?? this.tunnelMeters,
      axisConfidence: axisConfidence ?? this.axisConfidence,
    );
  }

  static const DistanceEngineState initial = DistanceEngineState(
    source: DistanceSource.gps,
    tunnelMode: false,
    manualTunnel: false,
    reconciling: false,
    speedMps: 0,
    tunnelSince: null,
    tunnelMeters: 0,
    axisConfidence: 0,
  );
}
