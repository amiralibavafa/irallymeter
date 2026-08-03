import 'dart:math' as math;

/// Geodesic helpers. Self-contained so trip integration does not depend on the
/// geolocator package at the domain layer (keeps domain testable + pure).
class GeoMath {
  GeoMath._();

  static const double _earthRadiusM = 6371000.0;

  static double _deg2rad(double d) => d * (math.pi / 180.0);
  static double _rad2deg(double r) => r * (180.0 / math.pi);

  /// Haversine great-circle distance in metres between two WGS84 points.
  static double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusM * c;
  }

  /// Initial bearing (0..360, clockwise from north) from point 1 to point 2.
  static double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = _deg2rad(lat1);
    final phi2 = _deg2rad(lat2);
    final dLon = _deg2rad(lon2 - lon1);
    final y = math.sin(dLon) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    final theta = math.atan2(y, x);
    return (_rad2deg(theta) + 360.0) % 360.0;
  }

  /// Shortest signed angular difference a→b in degrees, range (-180, 180].
  /// Used so heading EMA filtering wraps correctly across the 0/360 seam.
  static double angleDelta(double a, double b) {
    var diff = (b - a + 540.0) % 360.0 - 180.0;
    return diff;
  }

  /// EMA over a circular angle (degrees) that respects the 0/360 wrap.
  static double smoothAngle(double previous, double next, double alpha) {
    final delta = angleDelta(previous, next);
    return (previous + alpha * delta + 360.0) % 360.0;
  }

  /// 16-point compass abbreviation for a heading.
  static String cardinal(double deg) {
    const points = [
      'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', //
      'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW',
    ];
    final i = ((deg % 360) / 22.5).round() % 16;
    return points[i];
  }
}
