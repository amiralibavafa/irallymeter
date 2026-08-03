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

  // Request location up front so the GPS stream can start immediately. We
  // ignore the result here; the status bar surfaces "GPS LOST" if denied.
  await GeolocatorGpsService().ensurePermission();

  // Android 13+ needs POST_NOTIFICATIONS for the GPS foreground-service
  // notification. If it's denied the foreground service can fail to start,
  // which previously froze speed + trip distance. Best-effort request.
  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
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
