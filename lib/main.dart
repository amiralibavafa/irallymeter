import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/di/providers.dart';
import 'core/storage/storage_service.dart';
import 'features/gps/data/geolocator_gps_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keep the device screen on for the whole time the app is in the foreground —
  // a co-driver's cluster must never blank out mid-stage. This holds the screen
  // awake regardless of which page is showing.
  await WakelockPlus.enable();

  // Keep the cluster awake while driving and bias to landscape (co-driver).
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
  ]);

  // Initialise persistence before the app reads any settings/trip values.
  final storage = await StorageService.init();

  // Request location and notifications up front so the GPS stream can start
  // immediately. Both are BEST EFFORT and neither may ever gate the first frame.
  //
  // These used to be bare awaits. On the first-ever run of this app they threw
  //   PlatformException(PermissionHandler.PermissionManager,
  //                     'A request for permissions is already running')
  // — two permission requests overlapping — and because they sit BEFORE
  // runApp, the exception meant runApp was never reached and the app hung on
  // the Flutter splash screen forever. There was no timeout and no error path:
  // a brand-new user's app simply never started.
  //
  // It did not reproduce on a later clean reinstall, so the race is
  // intermittent. The structural hazard is not: any throw here is fatal to
  // launch. Catching makes the app boot regardless, and the UI degrades
  // honestly on its own — the status bar already surfaces GPS LOST.
  try {
    await GeolocatorGpsService().ensurePermission();
  } catch (e) {
    // ignore: avoid_print
    print('iRallyMeter: location permission request failed ($e) — continuing');
  }

  try {
    // Android 13+ needs POST_NOTIFICATIONS for the GPS foreground-service
    // notification. If it's denied the foreground service can fail to start,
    // which previously froze speed + trip distance.
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  } catch (e) {
    // ignore: avoid_print
    print('iRallyMeter: notification permission request failed ($e) — '
        'continuing');
  }

  runApp(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
      ],
      child: const IRallyMeterApp(),
    ),
  );
}
