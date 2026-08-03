import '../domain/route_session.dart';

/// Minimal, dependency-free GPX 1.1 reader/writer. Hand-rolled (no XML package)
/// because GPX is simple and we want zero codegen / parser surprises in the
/// field. Handles `<trkpt>` with optional `<ele>`, `<time>` and Garmin/rally
/// `<speed>` extensions.
class GpxCodec {
  GpxCodec._();

  static String encode(RouteSession session) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="iRallyMeter" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata>')
      ..writeln('    <name>${_esc(session.name)}</name>')
      ..writeln('    <time>${session.startedAt.toUtc().toIso8601String()}</time>')
      ..writeln('  </metadata>')
      ..writeln('  <trk>')
      ..writeln('    <name>${_esc(session.name)}</name>')
      ..writeln('    <trkseg>');
    for (final p in session.points) {
      b
        ..writeln('      <trkpt lat="${p.lat}" lon="${p.lon}">')
        ..writeln('        <ele>${p.ele}</ele>')
        ..writeln('        <time>${p.time.toUtc().toIso8601String()}</time>')
        ..writeln('        <extensions><speed>${p.speedMps}</speed></extensions>')
        ..writeln('      </trkpt>');
    }
    b
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');
    return b.toString();
  }

  /// Parse track points from a GPX document. Tolerant: pulls every `<trkpt>`
  /// regardless of segment/track nesting.
  static List<TrackPoint> decode(String xml) {
    final points = <TrackPoint>[];
    final trkptRe = RegExp(
      r'<trkpt\b([^>]*?)>(.*?)</trkpt>|<trkpt\b([^>]*?)/>',
      caseSensitive: false,
      dotAll: true,
    );
    final latRe = RegExp(r'lat\s*=\s*"([\-0-9.eE]+)"');
    final lonRe = RegExp(r'lon\s*=\s*"([\-0-9.eE]+)"');
    final eleRe = RegExp(r'<ele>\s*([\-0-9.eE]+)\s*</ele>', caseSensitive: false);
    final timeRe = RegExp(r'<time>\s*(.*?)\s*</time>', caseSensitive: false);
    final speedRe = RegExp(r'<speed>\s*([\-0-9.eE]+)\s*</speed>', caseSensitive: false);

    for (final m in trkptRe.allMatches(xml)) {
      final attrs = m.group(1) ?? m.group(3) ?? '';
      final body = m.group(2) ?? '';
      final lat = double.tryParse(latRe.firstMatch(attrs)?.group(1) ?? '');
      final lon = double.tryParse(lonRe.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lon == null) continue;
      points.add(TrackPoint(
        lat: lat,
        lon: lon,
        ele: double.tryParse(eleRe.firstMatch(body)?.group(1) ?? '') ?? 0,
        time: DateTime.tryParse(timeRe.firstMatch(body)?.group(1) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        speedMps: double.tryParse(speedRe.firstMatch(body)?.group(1) ?? '') ?? 0,
      ));
    }
    return points;
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
