enum TimerMode { stopwatch, countdown }

/// Wall-clock-anchored timer state. Because elapsed time is derived from
/// [DateTime] anchors (not an incrementing counter), the timer stays accurate
/// across app backgrounding, screen-off and process suspension.
class StageTimerState {
  const StageTimerState({
    required this.mode,
    required this.running,
    required this.startedAt,
    required this.accumulated,
    required this.countdownTarget,
    required this.splits,
  });

  final TimerMode mode;
  final bool running;

  /// Wall-clock instant the current run segment began (null when paused).
  final DateTime? startedAt;

  /// Time banked from previous run segments.
  final Duration accumulated;

  /// Initial value for countdown mode (e.g. 1:00 to stage start).
  final Duration countdownTarget;

  final List<Duration> splits;

  /// Elapsed time at [now], independent of UI tick rate.
  Duration elapsed(DateTime now) {
    final live = running && startedAt != null ? now.difference(startedAt!) : Duration.zero;
    return accumulated + live;
  }

  /// For countdown mode: time remaining (can go negative = overrun).
  Duration remaining(DateTime now) => countdownTarget - elapsed(now);

  StageTimerState copyWith({
    TimerMode? mode,
    bool? running,
    DateTime? startedAt,
    bool clearStartedAt = false,
    Duration? accumulated,
    Duration? countdownTarget,
    List<Duration>? splits,
  }) {
    return StageTimerState(
      mode: mode ?? this.mode,
      running: running ?? this.running,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      accumulated: accumulated ?? this.accumulated,
      countdownTarget: countdownTarget ?? this.countdownTarget,
      splits: splits ?? this.splits,
    );
  }

  static const StageTimerState initial = StageTimerState(
    mode: TimerMode.stopwatch,
    running: false,
    startedAt: null,
    accumulated: Duration.zero,
    countdownTarget: Duration(minutes: 1),
    splits: [],
  );
}

/// Parsing and bounds for the countdown target.
///
/// Lives in the domain, not in the widget, for one reason: this is the code
/// that stands between a typo and a crew's countdown finishing the instant it
/// starts. It is worth testing, and a private static inside a dialog is not
/// reachable from a test.
class CountdownTarget {
  CountdownTarget._();

  /// Shortest legal target. Below this the countdown is over before anyone
  /// can look up.
  static const min = Duration(seconds: 10);

  /// Longest legal target.
  static const max = Duration(hours: 1);

  static Duration clamp(Duration d) => d < min ? min : (d > max ? max : d);

  /// Parses `m:ss` / `mm:ss`, or a bare number read as SECONDS.
  ///
  /// Returns **null** on anything it does not fully understand, and the caller
  /// leaves the existing target alone. That is deliberate: silently coercing a
  /// typo into *some* duration is how a crew ends up counting down to the wrong
  /// moment without ever being told.
  ///
  /// Seconds above 59 are rejected rather than carried, because `4:75` is a
  /// mistake, not a request for 5:15.
  static Duration? parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    if (parts.length == 1) {
      final s = int.tryParse(parts[0]);
      return (s == null || s < 0) ? null : Duration(seconds: s);
    }
    if (parts.length != 2) return null;
    final m = int.tryParse(parts[0]);
    final sec = int.tryParse(parts[1]);
    if (m == null || sec == null || m < 0 || sec < 0 || sec > 59) return null;
    return Duration(minutes: m, seconds: sec);
  }
}
