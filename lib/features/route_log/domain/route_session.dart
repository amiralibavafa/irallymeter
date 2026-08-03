/// A single recorded track point.
class TrackPoint {
  const TrackPoint({
    required this.lat,
    required this.lon,
    required this.ele,
    required this.time,
    required this.speedMps,
  });

  final double lat;
  final double lon;
  final double ele;
  final DateTime time;
  final double speedMps;

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'ele': ele,
        't': time.toUtc().toIso8601String(),
        's': speedMps,
      };

  factory TrackPoint.fromJson(Map<String, dynamic> j) => TrackPoint(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        ele: (j['ele'] as num?)?.toDouble() ?? 0,
        time: DateTime.tryParse(j['t'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        speedMps: (j['s'] as num?)?.toDouble() ?? 0,
      );
}

/// A recorded route/session: an ordered list of track points plus metadata.
class RouteSession {
  RouteSession({
    required this.id,
    required this.name,
    required this.startedAt,
    required this.points,
    this.distanceMeters = 0,
  });

  final String id;
  final String name;
  final DateTime startedAt;
  final List<TrackPoint> points;
  final double distanceMeters;

  RouteSession copyWith({
    String? name,
    List<TrackPoint>? points,
    double? distanceMeters,
  }) {
    return RouteSession(
      id: id,
      name: name ?? this.name,
      startedAt: startedAt,
      points: points ?? this.points,
      distanceMeters: distanceMeters ?? this.distanceMeters,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'distance': distanceMeters,
        'points': points.map((p) => p.toJson()).toList(),
      };

  factory RouteSession.fromJson(Map<String, dynamic> j) => RouteSession(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Session',
        startedAt: DateTime.tryParse(j['startedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        distanceMeters: (j['distance'] as num?)?.toDouble() ?? 0,
        points: ((j['points'] as List?) ?? const [])
            .map((e) => TrackPoint.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}
