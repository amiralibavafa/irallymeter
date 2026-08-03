import 'motion_sample.dart';

/// Abstraction over the platform motion sensors, mirroring [GpsRepository] so
/// the distance engine never imports a plugin directly — the sensor fallback
/// can be driven from a fake in tests and replayed in simulation.
///
/// Cross-platform by construction: accelerometer + gyroscope are the only
/// inputs, and both are available on every Android and iOS device the app
/// targets. No platform branches live below this seam.
abstract class MotionRepository {
  /// Fused accelerometer + gyroscope stream in the device frame.
  ///
  /// Implementations MUST NOT throw on an absent/failed sensor — a device with
  /// no gyroscope should simply emit samples with a zero [MotionSample.gyro]
  /// rather than killing the stream, because the distance engine treats this as
  /// a best-effort fallback, never a hard dependency.
  Stream<MotionSample> motionStream();
}
