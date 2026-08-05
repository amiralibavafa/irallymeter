import '../../../core/constants/app_constants.dart';

/// A single immutable GPS fix, decoupled from the geolocator package so the
/// domain + trip logic stay pure and unit-testable.
class GpsSample {
  const GpsSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.speedMps,
    required this.headingDeg,
    required this.accuracyM,
    required this.altitudeM,
    required this.hasFix,
    this.speedAccuracyMps = double.nan,
    this.stalled = false,
    this.errorMessage,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;

  /// Raw GNSS Doppler ground speed in m/s, exactly as the receiver reported it
  /// — including negative and NaN.
  ///
  /// Deliberately NOT sanitised at this boundary. Coercing an unusable reading
  /// to `0` here is indistinguishable from a genuine standstill downstream, and
  /// that is precisely what killed the fallback path SPEC-v2 §7.1 requires:
  /// the derivation from consecutive positions could never fire, because by
  /// the time anything looked, the bad value had already become a plausible
  /// one. Judge validity with [hasValidDopplerSpeed]; never by `== 0`.
  final double speedMps;

  /// Reported uncertainty on [speedMps] in m/s, or NaN when the platform gave
  /// none. SPEC-v2 §7.1 invalidates a speed whose accuracy is worse than 2 m/s.
  final double speedAccuracyMps;

  /// True only on the synthetic sample emitted when the WATCHDOG tore down and
  /// rebuilt a dead subscription.
  ///
  /// This exists to keep two things apart that otherwise look identical
  /// downstream, because both arrive as a no-fix sample:
  ///
  ///   * a TUNNEL — silence with location services up the whole time. Normal,
  ///     expected, and must never be counted as a fault.
  ///   * a STALL — silence that persisted across services going off and back
  ///     on, meaning the old subscription is dead.
  ///
  /// SPEC-v2 §19 row 6 is measured on the second one only, and `ROAD-TEST.md`
  /// item 2 requires it to read zero THROUGH a tunnel. Without this flag the
  /// health panel cannot tell them apart, which is why its counter sat at zero
  /// no matter what happened.
  final bool stalled;

  /// The platform failure this synthetic sample is reporting, or null on every
  /// ordinary sample.
  ///
  /// The service's retry loop catches every platform error so one failure
  /// cannot end the stream for the rest of the drive. That is correct, and it
  /// had a cost nobody had noticed: the error was converted to a plain
  /// [GpsSample.noFix] — byte for byte what a TUNNEL emits — so it never
  /// reached the consumer as an error at all. `gpsStateProvider`'s error branch
  /// and the `GPS ERROR` status were unreachable in the shipped app, and a
  /// revoked permission read as `GPS LOST`.
  ///
  /// Those two need opposite responses from the crew: a tunnel is waited out, a
  /// revoked permission has to be acted on. Carrying the message ON the sample
  /// keeps the retry behaviour exactly as it is — the stream still never errors
  /// — while making the failure visible. Same shape as [stalled]: the loop
  /// already knows which kind of event it is emitting, so it says so, rather
  /// than leaving a consumer to guess from a value that cannot distinguish.
  final String? errorMessage;

  /// Course over ground in degrees (0..360). NaN when not moving.
  final double headingDeg;

  /// Horizontal accuracy in metres (lower is better).
  final double accuracyM;
  final double altitudeM;

  /// False represents a synthetic "no fix" placeholder.
  final bool hasFix;

  bool get isUsable => hasFix && accuracyM > 0;

  /// Whether the Doppler speed may be used as the primary source (SPEC-v2 §7.1).
  ///
  /// The single home of that rule, so "is this speed trustworthy" is answered
  /// identically by the distance source, the display filter and the estimator.
  /// Invalid when negative, non-finite, or reported with an accuracy worse than
  /// [AppConstants.maxUsableSpeedAccuracyMps].
  ///
  /// A *missing* accuracy (NaN) is treated as acceptable rather than fatal: not
  /// every platform reports one, and rejecting every fix on a device that omits
  /// the field would silently disable the primary speed source entirely — a far
  /// worse failure than trusting an unqualified reading.
  bool get hasValidDopplerSpeed =>
      speedMps.isFinite &&
      speedMps >= 0 &&
      (speedAccuracyMps.isNaN ||
          speedAccuracyMps <= AppConstants.maxUsableSpeedAccuracyMps);

  /// Empty/no-fix sample used as the stream's initial value.
  /// The watchdog rebuilt a dead subscription. Counted by [GpsHealthStats].
  factory GpsSample.stalled() => GpsSample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        latitude: 0,
        longitude: 0,
        speedMps: 0,
        headingDeg: double.nan,
        accuracyM: -1,
        altitudeM: 0,
        hasFix: false,
        stalled: true,
      );

  /// The platform stream failed. Carries [errorMessage] so the cluster can say
  /// GPS ERROR rather than GPS LOST; the service still retries underneath.
  factory GpsSample.error(String message) => GpsSample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        latitude: 0,
        longitude: 0,
        speedMps: 0,
        headingDeg: double.nan,
        accuracyM: -1,
        altitudeM: 0,
        hasFix: false,
        errorMessage: message,
      );

  factory GpsSample.noFix() => GpsSample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
        latitude: 0,
        longitude: 0,
        speedMps: 0,
        headingDeg: double.nan,
        accuracyM: -1,
        altitudeM: 0,
        hasFix: false,
      );
}

/// Quality buckets that drive the status colour on the dashboard.
enum FixQuality { none, poor, fair, good }
