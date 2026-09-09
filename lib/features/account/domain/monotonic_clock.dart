import '../data/secure_store.dart';

/// A clock that can only ever move **forward**.
///
/// ══ WHY THIS EXISTS AT ALL ══
///
/// `SPEC.md` §4 is explicit that server time is the authority and the device
/// clock is never trusted. Offline — which is the entire point of the
/// entitlement blob — there is no server, so the app has nothing but its own
/// clock. That tension cannot be designed away, only bounded:
///
///  · Winding the clock **forward** only ends access sooner. Safe, ignored.
///  · Winding it **backward** would extend access past a real expiry. That is
///    the attack, and this class is the whole defence against it.
///
/// ⚠ It carries more weight here than the design originally intended. The
/// backend does not emit `graceDays` (`DEVIATIONS.md` D-1), so `now >= iat`
/// and this mark are *all* that stand between a rolled-back clock and a free
/// subscription. That is why the mark ratchets and persists rather than being
/// advisory.
class MonotonicClock {
  MonotonicClock(this._store, {DateTime Function()? wallClock})
      : _wall = wallClock ?? (() => DateTime.now().toUtc());

  final SecureStore _store;
  final DateTime Function() _wall;

  /// The current time, as the high-water mark of everything ever seen.
  ///
  /// **This both reads and writes.** Every call where the wall clock has moved
  /// past the mark advances the mark, which is what makes the defence work
  /// across a period of ordinary offline use: a device that has been running
  /// for twenty days has a mark twenty days old, so rolling the clock back to
  /// day five cannot restore an expired entitlement.
  ///
  /// The write cost is not a concern because `INTERFACES.md` §5 evaluates
  /// entitlement **at session start only**, never mid-session — a co-driver's
  /// numbers must not blank at speed.
  Future<DateTime> now() async {
    final DateTime wall = _wall().toUtc();
    return _advance(wall);
  }

  /// Records server truth. Called with `serverTime` from every
  /// `GET /subscription/status`, which `INTERFACES.md` §3 returns precisely so
  /// the client never has to trust its own clock.
  Future<void> observe(DateTime serverTime) async {
    await _advance(serverTime.toUtc());
  }

  /// Returns the later of [candidate] and the stored mark, persisting
  /// [candidate] when it is the later one.
  Future<DateTime> _advance(DateTime candidate) async {
    final DateTime? mark = await _readMark();
    if (mark != null && !candidate.isAfter(mark)) return mark;
    await _store.write(SecureKeys.clockMark, candidate.toIso8601String());
    return candidate;
  }

  Future<DateTime?> _readMark() async {
    final String? raw = await _store.read(SecureKeys.clockMark);
    if (raw == null) return null;
    // A corrupt mark must not brick entitlement. Treating it as absent is the
    // safe direction: the mark can only ever make the client STRICTER, so
    // losing it degrades to plain wall-clock behaviour rather than to a
    // permanent lockout.
    return DateTime.tryParse(raw)?.toUtc();
  }
}
