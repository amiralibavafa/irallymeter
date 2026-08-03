import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/utils/geo_math.dart';
import '../../../gps/domain/gps_sample.dart';
import '../../../gps/presentation/providers/gps_providers.dart';
import '../../data/route_log_repository.dart';
import '../../domain/route_session.dart';

final routeLogRepositoryProvider = Provider<RouteLogRepository>((ref) {
  return RouteLogRepository(ref.watch(storageProvider));
});

/// Live state of the active recording (or idle).
class RecordingState {
  const RecordingState({
    required this.recording,
    required this.points,
    required this.distanceMeters,
  });

  final bool recording;
  final List<TrackPoint> points;
  final double distanceMeters;

  static const idle = RecordingState(recording: false, points: [], distanceMeters: 0);
}

/// Records the live track from the RAW GPS stream while active. Decoupled from
/// the trip computer so you can record a track without affecting trip values.
class RouteRecorder extends Notifier<RecordingState> {
  late final RouteLogRepository _repo;
  DateTime? _startedAt;
  TrackPoint? _last;

  @override
  RecordingState build() {
    _repo = ref.watch(routeLogRepositoryProvider);

    ref.listen<AsyncValue<GpsSample>>(rawGpsStreamProvider, (_, next) {
      final s = next.valueOrNull;
      if (s != null && s.hasFix) _onSample(s);
    });

    return RecordingState.idle;
  }

  void _onSample(GpsSample s) {
    if (!state.recording) return;
    if (s.accuracyM <= 0 || s.accuracyM > AppConstants.usableAccuracyMeters) return;

    final point = TrackPoint(
      lat: s.latitude,
      lon: s.longitude,
      ele: s.altitudeM,
      time: s.timestamp,
      speedMps: s.speedMps,
    );

    var added = state.distanceMeters;
    final prev = _last;
    if (prev != null) {
      final d = GeoMath.distanceMeters(prev.lat, prev.lon, point.lat, point.lon);
      if (d < AppConstants.minMovementMeters) return; // skip near-duplicates
      added += d;
    }
    _last = point;
    state = RecordingState(
      recording: true,
      points: [...state.points, point],
      distanceMeters: added,
    );
  }

  void start() {
    if (state.recording) return;
    _startedAt = DateTime.now();
    _last = null;
    state = const RecordingState(recording: true, points: [], distanceMeters: 0);
  }

  /// Stop and persist. Returns the saved session, or null if nothing recorded.
  Future<RouteSession?> stopAndSave({String? name}) async {
    if (!state.recording) return null;
    final started = _startedAt ?? DateTime.now();
    final points = state.points;
    state = RecordingState.idle;
    if (points.isEmpty) return null;

    final session = RouteSession(
      id: 'sess_${started.millisecondsSinceEpoch}',
      name: name ?? 'Stage ${started.toLocal()}',
      startedAt: started,
      points: points,
      distanceMeters: state.distanceMeters,
    );
    await _repo.upsert(session);
    return session;
  }

  void discard() {
    _last = null;
    state = RecordingState.idle;
  }
}

final routeRecorderProvider =
    NotifierProvider<RouteRecorder, RecordingState>(RouteRecorder.new);

/// All saved sessions, newest first.
final savedSessionsProvider = Provider<List<RouteSession>>((ref) {
  // Recompute when a recording finishes (the recorder writes to the repo).
  ref.watch(routeRecorderProvider.select((s) => s.recording));
  return ref.watch(routeLogRepositoryProvider).loadAll();
});
