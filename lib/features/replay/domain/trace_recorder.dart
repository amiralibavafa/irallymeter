import '../../distance/domain/motion_sample.dart';
import '../../gps/domain/gps_sample.dart';
import 'trace_event.dart';

/// Records the raw location and motion stream to JSON Lines (SPEC-v2 §20.1).
///
/// "During real drives, log the raw location and sensor stream to a file.
/// These recordings are then replayed against the Distance Engine inside unit
/// tests." That is what this is for, and it is why it records the stream
/// BEFORE any gating or smoothing: a recording of already-filtered data cannot
/// be used to tune the filter, which is the main thing the traces exist for.
///
/// ## Debug-only, and enforced rather than documented
///
/// [enabled] defaults to `false`. Recording a drive means writing the user's
/// precise movements to disk, so it is opt-in per session and never the
/// default. Nothing here starts on its own.
///
/// ## Why it takes a sink instead of a path
///
/// The recorder emits strings and hands them to [sink]; it never opens a file.
/// That keeps `dart:io` out of `lib/` entirely — the domain stays pure per
/// SPEC-v2 §17, the recorder is testable with a list, and the app decides where
/// bytes land (`path_provider`, share sheet, `/dev/null`).
class TraceRecorder {
  TraceRecorder({required this.sink, this.enabled = false});

  /// Receives one complete JSONL line at a time, newline excluded.
  final void Function(String line) sink;

  final bool enabled;

  DateTime? _startedAt;

  bool get isRecording => _startedAt != null;

  /// Begin a trace. [at] becomes offset 0. Re-arming an active recorder is a
  /// no-op rather than an error — a double-tap on a debug button should not
  /// silently restart the clock and orphan everything already written.
  void start(DateTime at) {
    if (!enabled || _startedAt != null) return;
    _startedAt = at;
    sink('# irallymeter trace v1 · started $at');
  }

  void stop() => _startedAt = null;

  void recordGps(GpsSample s, {double speedAccuracyMps = double.nan}) {
    final offset = _offsetOf(s.timestamp);
    if (offset == null) return;
    sink(GpsTraceEvent(
      offsetMs: offset,
      latitude: s.latitude,
      longitude: s.longitude,
      speedMps: s.speedMps,
      speedAccuracyMps: speedAccuracyMps,
      headingDeg: s.headingDeg,
      accuracyM: s.accuracyM,
      altitudeM: s.altitudeM,
      hasFix: s.hasFix,
    ).toJsonLine());
  }

  void recordMotion(MotionSample m) {
    final offset = _offsetOf(m.timestamp);
    if (offset == null) return;
    sink(MotionTraceEvent(
      offsetMs: offset,
      userAccel: m.userAccel,
      gravity: m.gravity,
      gyro: m.gyro,
    ).toJsonLine());
  }

  /// Offset from the trace start, or null when not recording.
  ///
  /// Samples timestamped before [start] are clamped to 0 rather than dropped.
  /// A negative offset would sort ahead of the header and make the trace
  /// non-monotonic, and the platform can hand back a fix acquired moments
  /// before recording began.
  int? _offsetOf(DateTime t) {
    final started = _startedAt;
    if (started == null) return null;
    final ms = t.difference(started).inMilliseconds;
    return ms < 0 ? 0 : ms;
  }
}
