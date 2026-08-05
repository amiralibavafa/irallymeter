import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/utils/angle_smoother.dart';
import '../domain/heading_calibration.dart';

/// Tilt-compensated magnetic compass built from the accelerometer +
/// magnetometer (the rally cluster's heading when stationary; GPS course is
/// used instead when moving — see the dashboard heading provider).
///
/// Uses the standard Android rotation-matrix azimuth derivation so heading
/// stays correct even when the device is tilted on a dash mount.
class CompassService {
  StreamController<double>? _controller;
  StreamSubscription? _accelSub;
  StreamSubscription? _magSub;

  // Latest sensor vectors. Gravity is TIME-low-passed so vehicle acceleration
  // cannot corrupt "which way is down" — see [GravityLowPass].
  final GravityLowPass _gravity =
      GravityLowPass(AppConstants.gravityLowPassTau);
  double get _ax => _gravity.x;
  double get _ay => _gravity.y;
  double get _az => _gravity.z;
  double _mx = 0, _my = 0, _mz = 0;
  bool _haveMag = false;

  /// TIME-based, not sample-based. A fixed per-sample weight made the needle's
  /// lag a property of the device's magnetometer rate — see [AngleSmoother].
  final AngleSmoother _smoother =
      AngleSmoother(AppConstants.headingSmoothingTau);

  /// Smoothed magnetic heading in degrees (0..360). Null-safe: emits nothing
  /// until the magnetometer reports.
  Stream<double> headingStream() {
    _controller ??= StreamController<double>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
    return _controller!.stream;
  }

  void _start() {
    _accelSub = accelerometerEventStream().listen((e) {
      _gravity.add(e.x, e.y, e.z, DateTime.now());
    });
    _magSub = magnetometerEventStream().listen((e) {
      _mx = e.x;
      _my = e.y;
      _mz = e.z;
      _haveMag = true;
      _emit();
    });
  }

  void _emit() {
    if (!_haveMag) return;
    final heading = _computeAzimuth();
    if (heading == null) return;
    _controller?.add(_smoother.add(heading, DateTime.now()));
  }

  /// Rotation-matrix azimuth (degrees, 0..360) from gravity + magnetic field.
  /// Mirrors Android's `SensorManager.getRotationMatrix` + `getOrientation`:
  /// azimuth = atan2(R[1], R[4]) = atan2(Hy, My) with H, M normalised.
  double? _computeAzimuth() {
    // East axis  H = E × A  (geomagnetic × gravity), then normalise.
    var hx = _my * _az - _mz * _ay;
    var hy = _mz * _ax - _mx * _az;
    var hz = _mx * _ay - _my * _ax;
    final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (normH < 0.1) return null; // device pointing along field — undefined.
    hx /= normH;
    hy /= normH;
    hz /= normH;

    // Normalise gravity.
    final normA = math.sqrt(_ax * _ax + _ay * _ay + _az * _az);
    if (normA < 0.1) return null;
    final ax = _ax / normA, az = _az / normA;

    // North axis  M = A × H  (both already normalised → M is unit length).
    final my = az * hx - ax * hz;

    // azimuth = atan2(Hy, My)
    final azimuth = math.atan2(hy, my);
    return (azimuth * 180.0 / math.pi + 360.0) % 360.0;
  }

  void _stop() {
    _accelSub?.cancel();
    _magSub?.cancel();
    _accelSub = null;
    _magSub = null;
    _haveMag = false;
    _gravity.reset();
    _smoother.reset();
  }

  void dispose() {
    _stop();
    _controller?.close();
    _controller = null;
  }
}
