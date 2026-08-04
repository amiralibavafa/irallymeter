/// App-wide tuning constants. Centralised so rally tuning (filter strength,
/// GPS rates, persistence cadence) lives in one place.
class AppConstants {
  AppConstants._();

  static const String appName = 'iRallyMeter';

  // ---- GPS engine ----
  /// Distance (m) the device must move before a new position event fires.
  /// 0 = report every fix; rally needs continuous data so we keep it at 0 and
  /// rely on time-based interval instead.
  static const int gpsDistanceFilterMeters = 0;

  /// Target update interval. Most Android GPS chips deliver 1 Hz; high-end /
  /// fused providers can do up to 10 Hz. 200ms requests up to 5 Hz.
  static const Duration gpsInterval = Duration(milliseconds: 200);

  /// Below this horizontal accuracy (m) we treat speed/heading as reliable.
  static const double goodAccuracyMeters = 8;
  static const double usableAccuracyMeters = 25;

  /// Speeds below this (m/s ≈ 1.4 km/h) are clamped to zero to kill GPS
  /// jitter while stationary.
  static const double speedNoiseFloorMps = 0.4;

  /// SPEC-v2 §7.1: a Doppler speed reported with an accuracy worse than this
  /// (m/s) is not trustworthy, and the app derives speed from consecutive
  /// positions instead. See [GpsSample.hasValidDopplerSpeed].
  static const double maxUsableSpeedAccuracyMps = 2.0;

  /// SPEC-v2 §6.1 rule 4: a displacement more than this many times the one the
  /// last known speed predicted is a bad fix, not real movement.
  static const double maxJumpFactor = 3.0;

  /// SPEC-v2 §7.1 / §6.1: the single "is the vehicle actually moving" line.
  /// Below this (m/s ≈ 5.4 km/h) the display shows 0 km/h, and §6.1 ignores
  /// the displacement entirely so a parked car cannot accumulate distance.
  static const double movingThresholdMps = 1.5;

  /// Time constant for the display speed filter (SPEC-v2 §7.2, §19 row 3).
  ///
  /// The filter is TIME-based, not sample-based, so its lag is a property of
  /// the clock rather than of whatever fix rate the chip delivers. This is the
  /// number that sets it.
  ///
  /// §19 budgets "latency <= 1.0 s" for the displayed speed and §7.2 says
  /// smoothing "must not add more than approximately 1 second of latency".
  /// Settling within +/-2 km/h of a large step takes roughly `tau * ln(step /
  /// tolerance)`, so 250 ms leaves the worst realistic step inside 1 s at both
  /// 1 Hz and 5 Hz.
  ///
  /// The previous value was a per-sample weight of 0.4, which measured 1.60 s
  /// at 5 Hz and 8.00 s at 1 Hz against that same 1 s budget.
  static const Duration speedSmoothingTau = Duration(milliseconds: 250);

  /// If no fix arrives within this window we consider the latest fix stale.
  static const Duration gpsStaleTimeout = Duration(seconds: 3);

  /// Consecutive 1 Hz stale ticks required before the status bar declares
  /// "GPS LOST". Adds hysteresis so a single skipped fix doesn't flap the
  /// warning; recovery is still instant on the next fresh fix.
  static const int gpsDropoutConfirmTicks = 2;

  /// How often to check in on a position stream that is delivering nothing.
  ///
  /// This is a HEARTBEAT, not a timeout. **Silence is not failure — a tunnel is
  /// silence**, and the whole product depends on surviving one. Each tick emits
  /// a synthetic no-fix sample so the dashboard can show the gap, and leaves the
  /// subscription completely untouched.
  ///
  /// An earlier attempt used a plain `.timeout()` here, which tore the stream
  /// down every 20 s. On device that produced a `Stopping location service` /
  /// `Start service in foreground mode` pair each time — roughly twenty
  /// restarts of the Android foreground service inside one 400 s tunnel. That is
  /// the exact service keeping the app alive in there, so the "fix" was more
  /// dangerous than the bug.
  static const Duration gpsSilenceCheck = Duration(seconds: 20);

  /// Silence this long, with location services ENABLED the whole time, is
  /// finally treated as a dead stream even without any other evidence.
  ///
  /// Deliberately longer than any real tunnel transit: Niayesh is 399 s at
  /// 60 km/h and Lærdal about 1102 s at 80. One re-subscribe after ten minutes
  /// is a rounding error; one every twenty seconds is a battery and reliability
  /// problem.
  static const Duration gpsSilenceHardLimit = Duration(minutes: 10);

  /// After the platform position stream errors or ends, wait this long before
  /// re-subscribing. Keeps the GPS engine self-healing instead of latching into
  /// a permanent "lost" state until the app is restarted.
  static const Duration gpsReconnectBackoff = Duration(milliseconds: 1500);

  // ---- Trip computer ----
  /// Ignore movement increments smaller than this (m) to avoid drift creep
  /// while parked. Tuned against typical 3–5 m standstill GPS wander.
  static const double minMovementMeters = 1.0;

  /// Persist trip/odometer at most this often (battery + flash wear).
  static const Duration tripPersistInterval = Duration(seconds: 5);

  /// Manual correction step sizes (m).
  static const List<int> correctionSteps = [10, 100];

  /// Calibration factor clamps. 1.0 = uncorrected GPS distance.
  static const double minCalibration = 0.80;
  static const double maxCalibration = 1.20;

  // ---- Compass ----
  /// EMA smoothing for heading to stop needle chatter.
  ///
  /// Still used for the GPS-course branch, which is sample-driven at the fix
  /// rate. The MAGNETIC branch now uses [headingSmoothingTau] instead — see
  /// below for why a per-sample weight was the wrong shape there.
  static const double headingSmoothing = 0.2;

  /// Time constant for the magnetic compass needle.
  ///
  /// The compass previously applied a fixed per-sample weight of 0.2 on every
  /// magnetometer event, which makes the lag a property of the device's sensor
  /// rate rather than of the clock: tau = dt / -ln(0.8), about 4.5 sample
  /// intervals. At sensors_plus's default 200 ms that is tau ~ 0.9 s and about
  /// 2.7 s to settle, and a different number on every handset. Reported from
  /// the road as "laggy, has a delay".
  ///
  /// 400 ms is deliberately steadier than the speed display's 250 ms: a needle
  /// that chatters is unreadable, and heading changes slower than speed does.
  static const Duration headingSmoothingTau = Duration(milliseconds: 400);

  /// Time constant for the gravity estimate used in compass tilt compensation.
  ///
  /// Gravity is constant; the only thing that legitimately moves it is the phone
  /// being re-seated in its mount. Vehicle acceleration is transient — a hard
  /// brake lasts a second or two — so a long constant rejects manoeuvring while
  /// still following a real re-orientation within a few seconds.
  ///
  /// The previous code used a fixed per-sample weight of 0.2, fast enough to
  /// track braking and cornering, so the tilt correction was wrong exactly when
  /// the car was manoeuvring.
  static const Duration gravityLowPassTau = Duration(seconds: 2);

  /// Observations needed before the app will call a magnetic heading "TRUE".
  ///
  /// The "Use true north" switch used to change only a LABEL — no declination
  /// was ever applied. Until this many agreeing GPS-course observations have
  /// been folded in, the cluster must keep saying MAG rather than asserting
  /// something it has not measured.
  static const int headingCalibrationSamples = 20;

  /// A GPS course is only direction-of-travel above this (m/s ~ 18 km/h).
  /// Far above the §6.1 moving gate on purpose: heading needs more evidence
  /// than distance does, and a crawling vehicle's course is noise.
  static const double headingCalibrationMinSpeedMps = 5.0;

  /// EMA rate for the learned magnetic/true offset. Slow: this is a property
  /// of the location and the vehicle's own steel, not something that should
  /// chase a single bad fix.
  static const double headingCalibrationSmoothing = 0.15;

  // ---- Tunnel handling / distance engine ----
  /// SPEC-v2 §15.1: "No location update received for more than 3 seconds,
  /// where updates are expected at 1 Hz." Long enough that a couple of skipped
  /// fixes don't flap the source, short enough that a real tunnel entry is
  /// caught almost immediately.
  static const Duration tunnelConfirmDelay = Duration(seconds: 3);

  /// SPEC-v2 §15.1: a fix this poor (m) means estimation is already better than
  /// what the receiver is offering, so Estimation Mode is entered at once
  /// rather than waiting out [tunnelConfirmDelay].
  ///
  /// Deliberately far looser than [usableAccuracyMeters], which governs whether
  /// a fix may be INTEGRATED. Between the two the engine neither integrates the
  /// fix nor abandons GPS — it waits, which is the right response to a fix that
  /// is degraded but not useless.
  static const double estimationEntryAccuracyMeters = 50.0;

  /// SPEC-v2 §15.2: "Three consecutive fixes with horizontal accuracy of 20 m
  /// or better." Stricter than the entry threshold on purpose — that gap IS the
  /// debouncing §15.2 asks for, and it is what stops the display flickering
  /// between modes at the edge of coverage.
  static const double estimationExitAccuracyMeters = 20.0;

  /// SPEC-v2 §15.2: how many consecutive good fixes confirm recovery.
  ///
  /// A COUNT, not a duration. A tunnel exit throws out a burst of wild fixes as
  /// the chip re-acquires, and what makes them trustworthy is that several
  /// agree — not that time passed. A duration would mean one fix on a 1 Hz chip
  /// and seven on a 5 Hz one.
  static const int estimationExitConsecutiveFixes = 3;

  /// How long a run of merely USABLE fixes may last before Estimation Mode ends
  /// anyway, even though none of them reached [estimationExitAccuracyMeters].
  ///
  /// Without this the engine latches. [usableAccuracyMeters] (25 m) is the bar
  /// for integrating a fix, and §15.2's exit bar is 20 m, so fixes landing in
  /// the 21-25 m band are good enough to MEASURE with but not good enough to
  /// ESCAPE with — and nothing else ends the mode. Light tree cover and shallow
  /// urban canyon sit in exactly that band, so the engine can dead-reckon from
  /// v0 indefinitely while usable truth streams past it. Measured in
  /// `tunnel_hardening_test` 31: a car halving its speed under a latch reported
  /// **2400 m against 1200 m of ground truth**, and an over-read is permanent
  /// because `_reconcileAgainst` pays out undershoot only.
  ///
  /// The window IS the cost, so it is deliberately short. While it runs the
  /// engine is still coasting at v0, so the distance it can invent is bounded
  /// by `(v0 - actualSpeed) x thisWindow` and by nothing else. At 30 s a car
  /// halving its speed invented 300 m; at 10 s it invents 100 m.
  ///
  /// 10 s is still strong evidence, because the run requires every fix in it to
  /// be MUTUALLY CONSISTENT with the last. A re-acquiring chip at a tunnel
  /// mouth throws out positions that fail exactly that test and restart the
  /// run. Re-entry is cheap too — §15.1 needs only 3 s of silence — so an early
  /// exit self-corrects within one [tunnelConfirmDelay] rather than stranding
  /// the engine.
  ///
  /// It does not weaken §15.2: three fixes at 20 m or better still exit
  /// immediately, as they always did. This decides only what happens when those
  /// never arrive, where the honest answer is that measuring beats guessing.
  static const Duration estimationExitUsableWindow = Duration(seconds: 10);

  /// SPEC-v2 §15.2: recovery fixes must be "mutually consistent — each implies
  /// a plausible speed relative to the previous one". This is that plausibility
  /// bound (m/s); a pair implying more is re-acquisition noise, not driving.
  static const double estimationExitMaxImpliedSpeedMps = 90.0;

  /// Engine heartbeat. Drives dropout detection (which must fire when samples
  /// STOP arriving, so it cannot be sample-driven) and reconciliation payout.
  static const Duration engineTick = Duration(milliseconds: 250);

  /// Plausible longitudinal acceleration band for a rally car (m/s²). Sensor
  /// estimates are clamped to this so an accelerometer spike (pothole, phone
  /// knocked in its mount) can never inject a speed jump.
  static const double maxPlausibleAccelMps2 = 4.0;

  /// SPEC-v2 §12.2: how far the accelerometer refinement may move the estimated
  /// speed away from the entry speed v₀, as a fraction of v₀. "Clamp the total
  /// adjustment to ±25% of v₀. If the correction wants to exceed this, ignore
  /// it and hold v₀."
  static const double maxSpeedAdjustFraction = 0.25;

  /// EMA smoothing for the sensor-estimated acceleration before integration.
  /// Low = heavily smoothed; raw phone accelerometers are far too noisy to
  /// integrate directly.
  static const double sensorAccelSmoothing = 0.15;

  /// Ignore motion samples separated by more than this — a gap means the
  /// sensor stream stalled (backgrounding) and integrating across it would
  /// invent distance.
  static const Duration motionMaxGap = Duration(milliseconds: 750);

  /// Learned forward-axis confidence required before the sensor fallback will
  /// trust the SIGN of its acceleration estimate. Below this we fall back to a
  /// constant-speed model (see [SensorDistanceSource]).
  static const double minAxisConfidence = 0.35;

  /// EMA rate at which the forward axis is learned while GPS is healthy.
  static const double axisLearningRate = 0.05;

  /// GPS |dv/dt| below this (m/s²) carries no usable signal for axis learning.
  static const double axisMinAccelSignal = 0.3;

  /// SPEC-v2 §12.3 confidence decay. Under 60 s without GNSS the estimate is
  /// shown as ordinary Estimation Mode; past 60 s the indicator becomes more
  /// prominent; past 180 s the display warns the distance may be significantly
  /// wrong.
  static const Duration reducedConfidenceAfter = Duration(seconds: 60);
  static const Duration lowConfidenceAfter = Duration(seconds: 180);

  /// SPEC-v2 §16.1: "Spread the correction linearly over 15 seconds."
  static const Duration reconcileWindow = Duration(seconds: 15);

  /// SPEC-v2 §16.1: "If the difference exceeds 200 m, spread it over 60 seconds
  /// instead and flag the event in the trip log." A correction that large is
  /// more likely to be a bad estimate than a real shortfall, so it is paid out
  /// four times more gently.
  static const double largeReconcileMeters = 200.0;
  static const Duration largeReconcileWindow = Duration(seconds: 60);

  /// Backstop on payout rate (m/s), for residuals outside §16.1's own envelope.
  ///
  /// Derived from the spec rather than picked: the fastest §16.1 ever asks for
  /// is the largest tier-1 residual over the tier-1 window, 200 m / 15 s.
  /// Anything under that pays out in exactly the window the spec names, so this
  /// never binds on a spec-compliant correction — it only stretches the absurd
  /// ones.
  ///
  /// It was previously 3.0 m/s, which bound on almost everything: a 50 m
  /// residual took 16.75 s against §19's 15 s cap, and no change to the window
  /// alone could have fixed that. The window and this ceiling are one decision.
  static const double maxReconcileRateMps = largeReconcileMeters / 15.0;

  /// Residuals below this (m) are noise — not worth reconciling.
  static const double minReconcileMeters = 0.5;

  /// Past this, a blackout is not a tunnel — **when we have no other evidence.**
  ///
  /// A backgrounded/suspended app stops receiving fixes exactly like a tunnel
  /// does, and on resume the entry→exit chord can be tens of kilometres of real
  /// driving we never saw. Reconciling that would dump it all onto the trip
  /// counter.
  ///
  /// **This used to be the ONLY test, and it was wrong.** The old comment here
  /// claimed 5 minutes "is not a practical limit on real tunnels" while citing
  /// Lærdal, which at 80 km/h takes 18 minutes — 3.7x over its own cap. Worse,
  /// it fails in the app's own market:
  ///
  ///   Niayesh, Tehran   6658 m @ 60 km/h = 399 s   OVER
  ///   Alborz, Tehran    6400 m @ 60 km/h = 384 s   OVER
  ///   Lærdal, Norway   24500 m @ 80 km/h = 1102 s  OVER
  ///
  /// So the app would have classified the second-longest urban tunnel in the
  /// world, which its users drive through, as a suspended app and silently
  /// declined to reconcile it.
  ///
  /// Duration was never the right discriminator. [motionContinuityGap] is:
  /// a suspended app stops delivering INERTIAL samples too, while a car in a
  /// tunnel keeps delivering them at 20 Hz. This cap now applies only as the
  /// fallback for when that evidence is missing.
  static const Duration maxTunnelDuration = Duration(minutes: 5);

  /// The blackout limit when the motion stream proves the app stayed alive.
  ///
  /// Generous enough for any real tunnel — Lærdal at 40 km/h is 37 minutes —
  /// while still bounding the absurd case.
  static const Duration maxTunnelDurationWithMotion = Duration(minutes: 45);

  /// A gap this long in the INERTIAL stream means the app was suspended, not
  /// that the car was in a tunnel. Motion normally arrives at ~20 Hz, so this
  /// is three orders of magnitude of slack — it fires on suspension, not on
  /// jitter.
  static const Duration motionContinuityGap = Duration(seconds: 5);

  /// How many §15.3 estimated sections to keep in memory.
  ///
  /// The log lives for the life of the app and a flaky receiver can produce
  /// hundreds of sections in a day, so it is bounded rather than unbounded.
  /// Generous enough that a real rally day never truncates: 200 sections is
  /// more dropouts than a working receiver has in a full stage.
  static const int maxLoggedSections = 200;
}
