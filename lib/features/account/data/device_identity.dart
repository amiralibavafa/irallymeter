import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'secure_store.dart';

/// The app version reported to the backend as `device.appVersion`.
///
/// Hard-coded rather than read at runtime, to avoid a fifth dependency for one
/// string. The obvious hazard is that it silently drifts from `pubspec.yaml`,
/// so `test/account/device_identity_test.dart` reads the pubspec and fails if
/// the two disagree. A constant with a test behind it is not a hard-coded
/// value in the sense the rules forbid; an undetected drift would be.
const String kAppVersion = '1.0.0+1';

/// Everything the backend is told about this handset, and nothing more.
///
/// `INTERFACES.md` §3 is deliberate about the size of this: `DEVICE_CONFLICT`
/// echoes `deviceName` back so a person can recognise *their own* other phone,
/// and it carries nothing else, because the same field would otherwise be a
/// profiling surface.
@immutable
class DeviceDescriptor {
  const DeviceDescriptor({
    required this.deviceId,
    required this.platform,
    required this.deviceName,
    required this.appVersion,
  });

  /// The persistent random installation UUID.
  ///
  /// ⚠ **Never IMEI. Never IP-as-identity** (`SPEC.md` §4). It is random, it
  /// identifies an *install* rather than a person or a handset, and it is
  /// generated on this device and never derived from anything about it.
  final String deviceId;

  /// `"android"` or `"ios"`.
  final String platform;

  /// A model name, e.g. `Pixel 7` or `iPhone 13`.
  final String deviceName;

  final String appVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'deviceId': deviceId,
        'platform': platform,
        'deviceName': deviceName,
        'appVersion': appVersion,
      };
}

/// Reads — and on first run, creates — this install's identity.
class DeviceIdentity {
  DeviceIdentity(
    this._store, {
    Random? random,
    Future<String> Function()? deviceNameReader,
    String? platformOverride,
  })  : _random = random ?? Random.secure(),
        _readDeviceName = deviceNameReader ?? _platformDeviceName,
        _platformOverride = platformOverride;

  final SecureStore _store;
  final Random _random;
  final Future<String> Function() _readDeviceName;
  final String? _platformOverride;

  /// The installation UUID, created on first call and stable forever after.
  ///
  /// ⚠ **Stable "forever" means something different on each platform, and the
  /// difference is a product consequence, not a bug to hide:**
  ///
  ///  · **iOS** — the keychain item survives an uninstall/reinstall, so a user
  ///    who reinstalls keeps the same device and walks straight back in.
  ///  · **Android** — there is no keychain equivalent; the encrypted store is
  ///    wiped with the app. A reinstalling user arrives as a *new* device and,
  ///    if their old one is still registered, meets `DEVICE_CONFLICT` against
  ///    their own phone. Force Login is the documented way out, and it costs
  ///    one SMS.
  ///
  /// Recorded here because the asymmetry is invisible until a real user hits
  /// it, and the honest fix is the Force Login path, not a weaker identifier.
  Future<String> installationId() async {
    final String? existing = await _store.read(SecureKeys.installationId);
    if (existing != null && _looksLikeUuidV4(existing)) return existing;

    // A malformed value is replaced rather than trusted. Reaching here with a
    // non-null `existing` means the store was corrupted or written by an older
    // build; either way a bad id would be rejected by the server on every call.
    final String fresh = _uuidV4();
    await _store.write(SecureKeys.installationId, fresh);
    return fresh;
  }

  Future<DeviceDescriptor> describe() async => DeviceDescriptor(
        deviceId: await installationId(),
        platform: _platformOverride ??
            (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'),
        deviceName: await _readDeviceName(),
        appVersion: kAppVersion,
      );

  /// Erases the installation UUID. **Deliberately not called by logout.**
  ///
  /// Logout ends a session; it does not make this a different phone. Rotating
  /// the id on logout would let one handset hold unlimited devices and would
  /// quietly defeat the one-device rule (`INTERFACES.md` §0 R4).
  Future<void> forgetForTesting() => _store.delete(SecureKeys.installationId);

  /// RFC 4122 version 4, from [Random.secure].
  ///
  /// Hand-rolled rather than pulling in `uuid`: it is sixteen random bytes with
  /// six bits pinned, and the version/variant nibbles are asserted by tests.
  String _uuidV4() {
    final List<int> bytes =
        List<int>.generate(16, (_) => _random.nextInt(256), growable: false);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    final String hex =
        bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static bool _looksLikeUuidV4(String value) =>
      _uuidV4Pattern.hasMatch(value.toLowerCase());

  static Future<String> _platformDeviceName() async {
    final DeviceInfoPlugin info = DeviceInfoPlugin();
    try {
      if (Platform.isIOS) {
        final IosDeviceInfo ios = await info.iosInfo;
        // `utsname.machine` is "iPhone14,2"; `model` is the friendlier
        // "iPhone". The name only has to be recognisable to its owner.
        return ios.name.isNotEmpty ? ios.name : ios.model;
      }
      final AndroidDeviceInfo android = await info.androidInfo;
      return '${android.manufacturer} ${android.model}'.trim();
    } catch (_) {
      // A missing plugin or a locked-down OEM build must never stop a login.
      // An unnamed device is a worse conflict screen, not a broken one.
      return 'Unknown device';
    }
  }
}
