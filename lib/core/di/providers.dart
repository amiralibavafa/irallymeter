import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_service.dart';

/// Root DI seam for persistence. Overridden in `main()` with the initialised
/// [StorageService] instance so the whole tree shares one Hive box. We throw
/// by default to make a missing override a loud, immediate error.
final storageProvider = Provider<StorageService>((ref) {
  throw UnimplementedError('storageProvider must be overridden in main()');
});

/// Whether the permission rationale (P3) has been completed. Seeded from
/// storage, flipped by the rationale screen.
///
/// The app root watches this before starting the GPS engine, and that is not
/// cosmetic: geolocator's `getPositionStream` raises the system location dialog
/// by itself. Without this gate the cold prompt would appear immediately, on
/// top of the very screen written to precede it.
final onboardedProvider = StateProvider<bool>(
  (ref) => ref.read(storageProvider).read(StorageKeys.onboarded, false),
);
