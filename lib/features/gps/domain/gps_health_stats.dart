import 'gps_sample.dart';

/// Live measurement of the things a road test has to report but nobody can
/// eyeball.
///
/// Two Phase 3 items were marked "cannot be verified" purely because nothing
/// was recording them:
///
///  * **§19 row 6 — "Location update rate ≥ 1 Hz sustained, foreground and
///    background."** A device property, so no unit test can assert it. But it
///    is trivially MEASURABLE, and unmeasured is not the same as unmeasurable.
///  * **the stream-recovery fix** (`[3.14]`/`[3.15]`), whose user-visible
///    symptom is a frozen trip counter. Counting stalls and re-subscribes turns
///    "did it come back?" from a memory test into a number.
///
/// Pure Dart, clock supplied by the caller, so it is unit-testable and can run
/// inside the engine's own test harness.
class GpsHealthStats {
  DateTime? _firstAt;
  DateTime? _lastAt;
  int _fixes = 0;

  double _accSum = 0;
  double _accMin = double.infinity;
  double _accMax = 0;

  Duration _longestGap = Duration.zero;
  int _gapsOver3s = 0;
  int _noFixSamples = 0;
  int _stalls = 0;

  int get fixes => _fixes;
  int get gapsOver3s => _gapsOver3s;
  int get noFixSamples => _noFixSamples;
  int get stalls => _stalls;
  Duration get longestGap => _longestGap;

  /// Wall-clock span covered by the samples seen so far.
  Duration get window => (_firstAt == null || _lastAt == null)
      ? Duration.zero
      : _lastAt!.difference(_firstAt!);

  /// SUSTAINED update rate in Hz — fixes divided by the whole window, so a
  /// burst followed by silence cannot flatter it. This is the §19 row 6 number.
  double get sustainedHz {
    final s = window.inMilliseconds / 1000.0;
    if (s <= 0 || _fixes < 2) return 0;
    return (_fixes - 1) / s;
  }

  bool get meetsRow6 => sustainedHz >= 1.0;

  double get meanAccuracyM => _fixes == 0 ? 0 : _accSum / _fixes;
  double get bestAccuracyM => _accMin.isFinite ? _accMin : 0;
  double get worstAccuracyM => _accMax;

  /// Fold in a sample exactly as the app received it.
  void add(GpsSample s, DateTime now) {
    // Counted here rather than left to a caller. `noteStall()` was public with
    // ZERO call sites, so STREAM STALLS was permanently 0 and the road-test
    // item that reads it could not have failed. Folding it into the one method
    // every sample already flows through means it cannot be forgotten again.
    if (s.stalled) noteStall();

    if (!s.hasFix || s.accuracyM <= 0) {
      // The watchdog's synthetic no-fix heartbeat, or an unusable reading.
      _noFixSamples++;
      return;
    }

    final last = _lastAt;
    if (last != null) {
      final gap = now.difference(last);
      if (gap > _longestGap) _longestGap = gap;
      if (gap > const Duration(seconds: 3)) _gapsOver3s++;
    }

    _firstAt ??= now;
    _lastAt = now;
    _fixes++;

    _accSum += s.accuracyM;
    if (s.accuracyM < _accMin) _accMin = s.accuracyM;
    if (s.accuracyM > _accMax) _accMax = s.accuracyM;
  }

  /// The position stream was torn down and rebuilt — see [GpsStallDetector].
  /// On a healthy drive this should stay at zero, INCLUDING through tunnels.
  void noteStall() => _stalls++;

  void reset() {
    _firstAt = null;
    _lastAt = null;
    _fixes = 0;
    _accSum = 0;
    _accMin = double.infinity;
    _accMax = 0;
    _longestGap = Duration.zero;
    _gapsOver3s = 0;
    _noFixSamples = 0;
    _stalls = 0;
  }
}
