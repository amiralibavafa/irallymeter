import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/gpx_file_service.dart';
import '../../domain/route_session.dart';
import 'route_log_providers.dart';

final gpxFileServiceProvider = Provider<GpxFileService>((ref) => GpxFileService());

/// Import a GPX file and persist it as a session. Returns it (or null).
final gpxImportProvider = Provider<Future<RouteSession?> Function()>((ref) {
  return () async {
    final session = await ref.read(gpxFileServiceProvider).pickAndImport();
    if (session != null) {
      await ref.read(routeLogRepositoryProvider).upsert(session);
    }
    return session;
  };
});
