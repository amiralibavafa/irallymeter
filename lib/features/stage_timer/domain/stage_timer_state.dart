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
