import 'dart:math' as math;

/// A minimal 3-vector. Local to the distance domain so the sensor maths stays
/// readable without pulling in a package for six lines of algebra.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x, y, z;

  static const Vec3 zero = Vec3(0, 0, 0);

  double get length => math.sqrt(x * x + y * y + z * z);

  bool get isFinite => x.isFinite && y.isFinite && z.isFinite;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  /// Unit vector, or null when too short to have a meaningful direction.
  Vec3? normalized({double epsilon = 1e-6}) {
    final l = length;
    if (!l.isFinite || l < epsilon) return null;
    return Vec3(x / l, y / l, z / l);
  }

  /// The component of this vector perpendicular to [unit] (which must already
  /// be normalised). Used to strip the vertical axis out of an acceleration
  /// reading, leaving only what the car did horizontally.
  Vec3 rejectFrom(Vec3 unit) => this - unit * dot(unit);
}

/// One fused motion reading in the DEVICE frame, decoupled from sensors_plus so
/// the estimation maths stays pure and unit-testable — the same seam
/// `GpsSample` gives the GPS pipeline.
class MotionSample {
  const MotionSample({
    required this.timestamp,
    required this.userAccel,
    required this.gravity,
    required this.gyro,
  });

  final DateTime timestamp;

  /// Acceleration with gravity already removed (m/s²).
  final Vec3 userAccel;

  /// Low-passed gravity vector (m/s²) — gives us "which way is down" without
  /// needing to know how the phone is sitting in its mount.
  final Vec3 gravity;

  /// Angular velocity (rad/s).
  final Vec3 gyro;

  bool get isUsable =>
      userAccel.isFinite && gravity.isFinite && gyro.isFinite && gravity.length > 1.0;
}
