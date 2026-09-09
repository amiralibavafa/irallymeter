import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/account_repository.dart';
import '../../data/api_client.dart';
import '../../data/device_identity.dart';
import '../../data/secure_store.dart';
import '../../domain/entitlement.dart';
import '../../domain/monotonic_clock.dart';

/// The backend's Ed25519 **public** key, SPKI PEM.
///
/// ══ TODO — NOT YET KNOWN. Supply at build time, same as the base URL. ══
///
///   --dart-define=IRALLYMETER_ENTITLEMENT_PUBLIC_KEY="$(cat public.pem)"
///
/// Only the public half ever ships. A client that could sign could forge, so
/// the private key never leaves the server (`INTERFACES.md` §5).
///
/// Empty is a supported state: the build then cannot verify a blob and falls
/// back to the stored subscription expiry rather than locking every user out.
/// See `DEVIATIONS.md` D-2 and [AccountRepository.restore].
const String kEntitlementPublicKeyPem = String.fromEnvironment(
  'IRALLYMETER_ENTITLEMENT_PUBLIC_KEY',
  defaultValue: '',
);

/// Overridden in `main()`, exactly like [storageProvider]. Throwing by default
/// makes a missing override loud and immediate rather than a null at launch.
final secureStoreProvider = Provider<SecureStore>((ref) {
  throw UnimplementedError('secureStoreProvider must be overridden in main()');
});

final accountApiProvider = Provider<AccountApi>((ref) {
  final AccountApi api = AccountApi();
  ref.onDispose(api.close);
  return api;
});

final monotonicClockProvider = Provider<MonotonicClock>(
  (ref) => MonotonicClock(ref.watch(secureStoreProvider)),
);

final deviceIdentityProvider = Provider<DeviceIdentity>(
  (ref) => DeviceIdentity(ref.watch(secureStoreProvider)),
);

/// Null when no key was compiled in, or when the compiled value is not a
/// usable Ed25519 SPKI key.
final entitlementVerifierProvider = Provider<EntitlementVerifier?>((ref) {
  if (kEntitlementPublicKeyPem.isEmpty) return null;
  try {
    return EntitlementVerifier.fromPem(kEntitlementPublicKeyPem);
  } on ArgumentError {
    // A malformed key must not stop the app from starting. Without a verifier
    // the repository falls back to the stored expiry, which is the same path a
    // build with no key at all takes.
    return null;
  }
});

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(
    store: ref.watch(secureStoreProvider),
    api: ref.watch(accountApiProvider),
    identity: ref.watch(deviceIdentityProvider),
    clock: ref.watch(monotonicClockProvider),
    verifier: ref.watch(entitlementVerifierProvider),
  ),
);

/// The launch decision. **Reads disk only** — see [AccountRepository.restore].
final gateStateProvider = FutureProvider<GateState>(
  (ref) => ref.watch(accountRepositoryProvider).restore(),
);
