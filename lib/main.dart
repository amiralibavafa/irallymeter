import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/di/providers.dart';
import 'core/storage/storage_service.dart';

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

  // NOTHING is requested here any more. Permissions are asked for exactly once,
  // by the rationale screen (P3), from inside a live widget.
  //
  // This block used to call both plugins on every launch, and for the user it
  // was meant to help it did nothing at all: an already-granted permission
  // makes `ensurePermission()` a no-op that never shows a dialog. The only
  // person it had any effect on was the one who had said NO — who then got a
  // bare system dialog with no explanation on their next launch, which is
  // precisely the thing the rationale screen exists to replace. Verified on
  // device: deny both, relaunch, and the cold prompt came straight back.
  //
  // It was also the launch path. On the first-ever run the two calls raced and
  // threw
  //   PlatformException(PermissionHandler.PermissionManager,
  //                     'A request for permissions is already running')
  // and because they sat BEFORE runApp, the app hung on the Flutter splash
  // screen forever. `P1` caught the throw; removing the calls removes the
  // hazard.
  //
  // A user who denied now degrades honestly — the status bar reads GPS LOST —
  // and the rationale screen's own footer points them at Android Settings.
  // There is deliberately no in-app retry yet; that is a product decision for
  // Amirali, not something to slip in here.

  runApp(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
      ],
      child: const IRallyMeterApp(),
    ),
  );
}
