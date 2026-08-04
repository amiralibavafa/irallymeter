import '../../../core/constants/app_constants.dart';

/// Decides whether a silent position stream is a TUNNEL or a DEAD SUBSCRIPTION.
///
/// This is the single most consequential judgement the app makes, and it is easy
/// to get backwards in both directions:
///
///  * Treat every silence as death and you tear the subscription down inside
///    every tunnel. Measured on device: a flat 20 s timeout produced about
///    twenty `Stopping location service` / `Start service in foreground mode`
///    pairs inside one 400 s tunnel — repeatedly killing the very foreground
///    service that keeps the receiver alive in there.
///  * Treat every silence as a tunnel and a genuinely dead stream never
///    recovers. Observed on device: after location services were switched off
///    and back on, the app sat in Estimation Mode with a frozen trip counter
///    and a red `EST?` badge until it was restarted. On a rally that is the
///    worst failure this app has.
///
/// So silence alone decides nothing. Resubscribing requires EVIDENCE:
///
///  1. location services were seen DISABLED and are now ENABLED again — the
///     subscription is bound to a provider that will never speak again, or
///  2. silence past [AppConstants.gpsSilenceHardLimit], which is longer than
///     any real tunnel transit, as a backstop for failure modes we have not
///     seen yet.
///
/// Pure Dart with no clock and no plugin: the caller supplies the tick and the
/// service state, which is what makes this testable at all. The live watchdog
/// around it cannot be unit-tested because it talks to static `Geolocator`
/// methods, so the logic lives here where it can be.
class GpsStallDetector {
  /// True once a tick has reported location services switched off. Latches: the
  /// point is to notice the OFF→ON transition later, so it must survive the
  /// ticks in between.
  bool _servicesWereOff = false;

  int _silentTicks = 0;

  bool get sawServicesDisabled => _servicesWereOff;
  int get silentTicks => _silentTicks;

  /// How long the stream has now been quiet.
  Duration get silentFor => AppConstants.gpsSilenceCheck * _silentTicks;

  /// Fold in one silence tick. [servicesEnabled] is the location-service state
  /// observed at (or just before) this tick.
  ///
  /// Returns true when the subscription should be torn down and rebuilt.
  bool onSilentTick({required bool servicesEnabled}) {
    _silentTicks++;

    if (!servicesEnabled) {
      // Nothing to resubscribe TO while the service is off, and this is not a
      // tunnel — remember it so the transition back is recognised.
      _servicesWereOff = true;
      return false;
    }

    if (_servicesWereOff) {
      // Off, then on, and still nothing arriving: the old subscription is dead.
      return true;
    }

    // Quiet, with services up the whole time. This is a tunnel. Leave the
    // subscription alone until the backstop.
    return silentFor >= AppConstants.gpsSilenceHardLimit;
  }

  /// A real fix arrived — everything is healthy again.
  void onData() {
    _silentTicks = 0;
    _servicesWereOff = false;
  }

  /// The subscription was rebuilt; start judging the new one from scratch.
  void reset() => onData();
}
