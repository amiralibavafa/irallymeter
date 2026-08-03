/// A rally-style tunnel marker: what the trip computer read at the instant the
/// driver pressed the button.
///
/// Pure Dart so the tunnel maths is unit-testable.
class TunnelMark {
  const TunnelMark({
    required this.at,
    required this.distanceMeters,
    required this.speedMps,
    required this.latitude,
    required this.longitude,
    required this.hasFix,
  });

  /// Wall-clock instant the marker was placed.
  final DateTime at;

  /// Trip A reading at that instant (m) — the counter a co-driver calls from.
  final double distanceMeters;

  /// Best speed estimate at that instant (m/s).
  final double speedMps;

  /// GPS position, when there was a fix. A tunnel-end marker frequently has
  /// none — that's the normal case, not an error.
  final double latitude;
  final double longitude;
  final bool hasFix;
}

/// A completed tunnel measurement.
class TunnelResult {
  const TunnelResult({
    required this.start,
    required this.end,
    required this.distanceMeters,
    required this.duration,
  });

  final TunnelMark start;
  final TunnelMark end;

  /// Distance covered between the two markers (m). Never negative.
  final double distanceMeters;

  /// Wall-clock time between the two markers.
  final Duration duration;

  /// Average speed through the tunnel (m/s). Zero when no time elapsed, so
  /// there is never a divide-by-zero.
  double get averageMps {
    final seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds <= 0) return 0;
    return distanceMeters / seconds;
  }

  /// Measure the leg between two markers.
  ///
  /// Distance is clamped at zero: the trip counter it reads from can be edited
  /// mid-tunnel (the ±10/±100 m roadbook correction pad), so an end reading
  /// below the start one is possible and must not produce negative distance.
  factory TunnelResult.between(TunnelMark start, TunnelMark end) {
    final meters = end.distanceMeters - start.distanceMeters;
    var duration = end.at.difference(start.at);
    if (duration.isNegative) duration = Duration.zero;
    return TunnelResult(
      start: start,
      end: end,
      distanceMeters: meters > 0 ? meters : 0,
      duration: duration,
    );
  }
}
