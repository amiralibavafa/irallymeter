import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/route_session.dart';
import 'gpx_codec.dart';

/// File-level GPX I/O: write/share an export, and pick/parse an import.
/// Separated from [GpxCodec] (pure string<->model) so the codec stays testable
/// without any plugin dependency.
class GpxFileService {
  /// Encode [session] to a .gpx file in the app's temp dir and open the OS
  /// share sheet. Returns the written file path.
  Future<String> exportAndShare(RouteSession session) async {
    final dir = await getTemporaryDirectory();
    final safeName = session.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/$safeName.gpx');
    await file.writeAsString(GpxCodec.encode(session));
    await Share.shareXFiles([XFile(file.path)], text: session.name);
    return file.path;
  }

  /// Prompt the user to pick a .gpx file and parse it into a session.
  /// Returns null if the user cancels or the file has no track points.
  Future<RouteSession?> pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null) return null;

    final xml = await File(path).readAsString();
    final points = GpxCodec.decode(xml);
    if (points.isEmpty) return null;

    final started = points.first.time.millisecondsSinceEpoch > 0
        ? points.first.time
        : DateTime.now();
    final name = path.split(Platform.pathSeparator).last.replaceAll('.gpx', '');
    return RouteSession(
      id: 'imp_${DateTime.now().millisecondsSinceEpoch}',
      name: 'Imported: $name',
      startedAt: started,
      points: points,
    );
  }
}
