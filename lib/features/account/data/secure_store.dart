import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The seam between the account layer and the platform keystore.
///
/// An interface rather than the plugin directly, for a reason that is not
/// abstraction for its own sake: every test under `test/` runs on the Dart VM
/// with no platform channels, so a direct dependency on [FlutterSecureStorage]
/// would make the installation UUID, the session store and the gate itself
/// untestable without a device.
///
/// ⚠ Everything written through here is a **secret**: the refresh token, the
/// installation UUID, the entitlement blob. Nothing here may be moved to Hive.
/// Hive is unencrypted by design (`ARCHITECTURE.md` §4), so a refresh token in
/// it is readable by anything that can read the app's files.
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keys in one place, for the same reason [StorageKeys] exists: a typo here is
/// silent, and its symptom is a user being logged out for no visible reason.
class SecureKeys {
  SecureKeys._();

  /// The persistent random installation UUID. **Never IMEI, never IP**
  /// (`SPEC.md` §4). Written exactly once per install.
  static const String installationId = 'account.installation_id';

  /// The refresh token. Secure storage ONLY — `INTERFACES.md` §2 says it never
  /// appears anywhere else, and in particular never in a request other than
  /// `/auth/refresh`.
  static const String refreshToken = 'account.refresh_token';

  /// The last session envelope, as JSON, minus the refresh token.
  static const String session = 'account.session';

  /// The compact JWS entitlement blob (`INTERFACES.md` §5). May be absent even
  /// for a valid session — see `DEVIATIONS.md` D-2.
  static const String entitlement = 'account.entitlement';

  /// The monotonic high-water mark, RFC 3339 UTC. See [MonotonicClock].
  static const String clockMark = 'account.clock_mark';
}

/// The real implementation, used by `main()` and by nothing else.
class PlatformSecureStore implements SecureStore {
  PlatformSecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(
              // ⚠ Deliberately the DEFAULTS on Android. The v9-era idiom was
              // `AndroidOptions(encryptedSharedPreferences: true)`; in 10.3.1
              // that parameter is deprecated AND ignored, and passing it moves
              // `flutter analyze` off its 2 pre-existing issues. The default is
              // already AES-GCM data encryption with RSA-OAEP key wrapping on
              // API 23+, and this app's minSdk is 24.
              aOptions: AndroidOptions(),
              // ⚠ `first_unlock_this_device`, not `first_unlock`, and the
              // difference is load-bearing for the one-device rule: the plain
              // variant is restorable onto a NEW handset from an iCloud
              // backup, which would put the same installation UUID on two
              // physical phones and let one account hold two devices without
              // ever calling Force Login. `_this_device` never leaves the
              // handset it was written on.
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
