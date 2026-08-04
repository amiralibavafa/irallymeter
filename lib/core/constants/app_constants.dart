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

  /// EMA smoothing factor for speed (0..1). Higher = snappier, lower = smoother.
  static const double speedSmoothing = 0.4;

  /// If no fix arrives within this window we consider the latest fix stale.
  static const Duration gpsStaleTimeout = Duration(seconds: 3);

  /// Consecutive 1 Hz stale ticks required before the status bar declares
  /// "GPS LOST". Adds hysteresis so a single skipped fix doesn't flap the
  /// warning; recovery is still instant on the next fresh fix.
  static const int gpsDropoutConfirmTicks = 2;

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
  static const double headingSmoothing = 0.2;

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

  /// Past this, a blackout is not a tunnel.
  ///
  /// A backgrounded/suspended app stops receiving fixes exactly like a tunnel
  /// does, and on resume the entry→exit chord can be tens of kilometres of real
  /// driving we never saw. Reconciling that would dump it all onto the trip
  /// counter. Beyond this age we re-anchor and decline to reconcile: unmeasured
  /// distance is bad, but inventing distance is far worse.
  ///
  /// The world's longest road tunnel (Lærdal, 24.5 km) takes ~18 min at 80 km/h,
  /// so this is not a practical limit on real tunnels — it's a sanity bound. It
  /// is generous because the sensor estimate's error grows linearly, so a
  /// genuinely long tunnel is already the estimate's problem, not this cap's.
  static const Duration maxTunnelDuration = Duration(minutes: 5);
}
