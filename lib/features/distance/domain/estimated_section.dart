import '../../../core/constants/app_constants.dart';

/// One completed stretch of driving that was estimated rather than measured.
///
/// SPEC-v2 §15.3 — "Automatic logging":
///
///   "Every estimated section is recorded automatically without user action:
///    start time, end time, and duration; estimated distance and the speed that
///    was held; the correction applied on recovery."
///
/// This is the replacement for the manual TUNNEL START / TUNNEL END buttons
/// §15 deleted, and the spec is explicit about why it is not merely a
/// like-for-like swap: the record is "measured rather than hand-triggered", and
/// it "gives us the data needed to tune the thresholds during testing". A
/// hand-triggered mark records when the driver noticed the tunnel; this records
/// when the receiver actually lost the sky.
///
/// Immutable and pure Dart — no clock, no plugins. Every timestamp is supplied
/// by the engine, so a replayed trace produces byte-identical sections.
class EstimatedSection {
  const EstimatedSection({
    required this.start,
    required this.end,
    required this.estimatedMeters,
    required this.heldSpeedMps,
    required this.correctionMeters,
    required this.largeCorrection,
  });

  /// When Estimation Mode was entered (§15.1).
  final DateTime start;

  /// When it was left (§15.2 — the third consecutive confirming fix).
  final DateTime end;

  /// Distance the sensor estimate accumulated over the section.
  final double estimatedMeters;

  /// The entry-speed anchor v₀ the estimate was seeded with (§12.2).
  ///
  /// "The speed that was held" is this number, not an average: §12.2 holds the
  /// entry speed and permits the accelerometer to refine it only within ±25 %.
  /// v₀ is therefore the figure that determines whether a section's estimate can
  /// be trusted at all, which is exactly what the threshold-tuning data needs.
  final double heldSpeedMps;

  /// Metres queued for payout when GNSS returned (§16.1). Zero when the exit
  /// produced no usable evidence — an overshoot, or a blackout too long to be a
  /// tunnel — in which case the estimate stands uncorrected.
  final double correctionMeters;

  /// Whether the payout used §16.1's slow 60 s window rather than the normal
  /// 15 s one. This is the spec's "flag the event in the trip log".
  ///
  /// It reflects the state of the PAYOUT, not this section's residual alone:
  /// §16.1 chooses the window from the reconciler's running total, so a modest
  /// correction landing on top of an unpaid one is flagged too. That is the
  /// behaviour being flagged — a correction large enough to be visible — so
  /// reading it off the payout is the honest place to take it from.
  final bool largeCorrection;

  Duration get duration => end.difference(start);

  /// True when the section ended without any correction being applied.
  bool get uncorrected => correctionMeters <= 0;

  /// The estimate's error against what GNSS could prove, as a fraction of the
  /// estimate. Null when nothing was proven (see [uncorrected]).
  ///
  /// Only ever positive: §16 corrects undershoot only, because the entry→exit
  /// chord is a lower bound on road distance and an overshoot proves nothing.
  double? get shortfallFraction {
    if (uncorrected || estimatedMeters <= 0) return null;
    return correctionMeters / estimatedMeters;
  }

  @override
  String toString() => 'EstimatedSection(${duration.inSeconds}s, '
      'est ${estimatedMeters.toStringAsFixed(1)}m @ '
      '${heldSpeedMps.toStringAsFixed(1)}m/s, '
      'corr ${correctionMeters.toStringAsFixed(1)}m'
      '${largeCorrection ? ' LARGE' : ''})';
}

/// The rolling record of [EstimatedSection]s for the current session.
///
/// Bounded on purpose. A rally on a bad receiver can drop and re-acquire
/// hundreds of times in a day, and this list lives for as long as the app does;
/// unbounded it is a slow leak on a device already running a screen-on GPS
/// session. Oldest entries are dropped first — the recent ones are the ones a
/// co-driver questions and the ones threshold tuning cares about.
class EstimatedSectionLog {
  EstimatedSectionLog({this.capacity = AppConstants.maxLoggedSections});

  final int capacity;
  final List<EstimatedSection> _sections = [];

  /// Oldest first. Unmodifiable — the log owns its own history.
  List<EstimatedSection> get sections => List.unmodifiable(_sections);

  int get length => _sections.length;
  bool get isEmpty => _sections.isEmpty;
  EstimatedSection? get last => _sections.isEmpty ? null : _sections.last;

  /// Total distance in this session that was estimated rather than measured.
  double get totalEstimatedMeters =>
      _sections.fold(0.0, (sum, s) => sum + s.estimatedMeters);

  /// Total time spent estimating.
  Duration get totalDuration =>
      _sections.fold(Duration.zero, (sum, s) => sum + s.duration);

  void add(EstimatedSection s) {
    _sections.add(s);
    if (_sections.length > capacity) {
      _sections.removeRange(0, _sections.length - capacity);
    }
  }

  void clear() => _sections.clear();
}
