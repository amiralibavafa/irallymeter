import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../domain/motion_repository.dart';
import '../domain/motion_sample.dart';

/// sensors_plus-backed implementation of [MotionRepository].
///
/// Fuses three cross-platform sensor streams into one [MotionSample]:
///  • `userAccelerometerEventStream` — acceleration with gravity removed.
///  • `accelerometerEventStream`     — low-passed to recover the gravity
///    vector, i.e. which way is down, so the maths above works at any mount
///    angle without asking the user to orient the phone.
///  • `gyroscopeEventStream`         — yaw rate, for cornering removal.
///
/// The user-accelerometer tick drives emission; the other two are latched. That
/// keeps the output rate stable and avoids emitting a sample built from a
/// half-updated set of readings.
///
/// Android and iOS both expose all three, so no platform branching is needed —
/// this is the only file in the feature that touches a plugin at all.
///
/// **Degrades, never fails.** A device without a gyroscope (or one that errors)
/// keeps streaming with a zero yaw rate rather than taking the stream down: the
/// fallback loses only cornering compensation, and a dead sensor stream would
/// otherwise take the tunnel estimate with it. Same for the gravity latch,
/// which is seeded to a sane "flat on its back" default until the real
/// accelerometer reports.
class SensorsMotionService implements MotionRepository {
  StreamController<MotionSample>? _controller;
  StreamSubscription<dynamic>? _userAccelSub;
  StreamSubscription<dynamic>? _accelSub;
  StreamSubscription<dynamic>? _gyroSub;

  // Latched readings. Gravity is seeded pointing down through the screen so a
  // sample emitted before the first accelerometer event is still usable.
  Vec3 _gravity = const Vec3(0, 0, 9.81);
  Vec3 _gyro = Vec3.zero;

  @override
  Stream<MotionSample> motionStream() {
    _controller ??= StreamController<MotionSample>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
    return _controller!.stream;
  }

  void _start() {
    // Low-pass the raw accelerometer to isolate gravity from motion — the same
    // technique CompassService already uses for its tilt compensation.
    _accelSub = _subscribe<AccelerometerEvent>(
      accelerometerEventStream,
      (e) {
        const a = 0.2;
        _gravity = Vec3(
          a * e.x + (1 - a) * _gravity.x,
          a * e.y + (1 - a) * _gravity.y,
          a * e.z + (1 - a) * _gravity.z,
        );
      },
      onFailure: () {}, // Keep the latch at its seeded/last good value.
    );

    _gyroSub = _subscribe<GyroscopeEvent>(
      gyroscopeEventStream,
      (e) => _gyro = Vec3(e.x, e.y, e.z),
      // No gyroscope → no cornering compensation, but the estimate still runs.
      onFailure: () => _gyro = Vec3.zero,
    );

    _userAccelSub = _subscribe<UserAccelerometerEvent>(
      userAccelerometerEventStream,
      (e) {
        final c = _controller;
        if (c == null || c.isClosed) return;
        c.add(MotionSample(
          timestamp: DateTime.now(),
          userAccel: Vec3(e.x, e.y, e.z),
          gravity: _gravity,
          gyro: _gyro,
        ));
      },
      onFailure: () {}, // No sensor → simply no estimate available.
    );
  }

  /// Subscribe to one sensor, tolerating every way it can be absent.
  ///
  /// A missing sensor shows up in three different shapes, and all three must be
  /// survivable: the stream factory can throw SYNCHRONOUSLY (no platform
  /// binding, plugin not registered), the stream can error later (sensor
  /// removed/denied at runtime), or it can simply never emit. Only the last two
  /// are catchable with `onError`, which is why the factory call is inside the
  /// try — an uncaught synchronous throw here would propagate out of
  /// `onListen` and take the whole distance engine down with it, turning "this
  /// phone has no gyroscope" into "trip distance stops working".
  StreamSubscription<T>? _subscribe<T>(
    Stream<T> Function() factory,
    void Function(T) onData, {
    required void Function() onFailure,
  }) {
    try {
      return factory().listen(onData, onError: (_) => onFailure(), cancelOnError: false);
    } catch (_) {
      onFailure();
      return null;
    }
  }

  void _stop() {
    _userAccelSub?.cancel();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _userAccelSub = null;
    _accelSub = null;
    _gyroSub = null;
    _gravity = const Vec3(0, 0, 9.81);
    _gyro = Vec3.zero;
  }

  void dispose() {
    _stop();
    _controller?.close();
    _controller = null;
  }
}
