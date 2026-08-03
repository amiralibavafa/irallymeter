import 'dart:convert';

import '../../../core/storage/storage_service.dart';
import '../domain/route_session.dart';

/// Persists recorded sessions as a list of JSON strings in Hive. Simple and
/// robust; for very long tracks the GPX export is the canonical artifact.
class RouteLogRepository {
  RouteLogRepository(this._storage);
  final StorageService _storage;

  List<RouteSession> loadAll() {
    return _storage
        .readStringList(StorageKeys.sessions)
        .map((s) => RouteSession.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  Future<void> saveAll(List<RouteSession> sessions) {
    final encoded = sessions.map((s) => jsonEncode(s.toJson())).toList();
    return _storage.writeStringList(StorageKeys.sessions, encoded);
  }

  Future<void> upsert(RouteSession session) async {
    final all = loadAll();
    final idx = all.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      all[idx] = session;
    } else {
      all.add(session);
    }
    await saveAll(all);
  }

  Future<void> delete(String id) async {
    final all = loadAll()..removeWhere((s) => s.id == id);
    await saveAll(all);
  }
}
