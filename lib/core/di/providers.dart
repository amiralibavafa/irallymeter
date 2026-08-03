import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_service.dart';

/// Root DI seam for persistence. Overridden in `main()` with the initialised
/// [StorageService] instance so the whole tree shares one Hive box. We throw
/// by default to make a missing override a loud, immediate error.
final storageProvider = Provider<StorageService>((ref) {
  throw UnimplementedError('storageProvider must be overridden in main()');
});
