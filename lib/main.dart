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
  //
  // NEVER RELEASED, AND THAT IS THE DECISION — reviewed 2026-08-05 and kept.
  //
  // `wakelock_plus` maps to FLAG_KEEP_SCREEN_ON on Android and
  // `idleTimerDisabled` on iOS, and BOTH only apply while the app is
  // foregrounded. So the actual behaviour is "the screen does not sleep while
  // the cluster is on screen", not a background battery leak, and there is
  // nothing to release on pause that the platform does not already release.
  //
  // Scoping it to an active trip was considered and rejected: this app has no
  // trip start/stop state (`TripState` holds only the two counters and the
  // odometer, and the engine starts unconditionally), so scoping would mean
  // inventing a product concept. The failure it would introduce is worse than
  // the one it fixes — a screen that blanks while stopped at a control or in
  // traffic is a cluster the crew cannot read at the moment they look down.
  //
  // The cost accepted in exchange: a phone left on the mount in a service park
  // with the app open keeps its screen lit.
  await WakelockPlus.enable();

  // Keep the cluster awake while driving and bias to landscape (co-driver).
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // NO ORIENTATION PREFERENCE — Saam's call, 2026-08-05: portrait by default,
  // and still able to rotate.
  //
  // MEASURED, because the obvious version of this change was wrong. It used to
  // be `[landscapeLeft, landscapeRight, portraitUp]` from Amirali's first
  // commit. Flutter does not treat that list as a priority order on Android: it
  // resolves it to a single `ActivityInfo` constant, and both that list and the
  // portrait-first version of it resolve to SCREEN_ORIENTATION_NOSENSOR — which
  // PINS the app to one orientation and ignores the sensor entirely.
  //
  // Verified on device via `dumpsys window`: with the old list the app was
  // effectively LANDSCAPE-LOCKED, which is why it never came up portrait even
  // on a phone held upright. Simply reversing the order moved the lock to
  // portrait and made landscape unreachable — with auto-rotate ON and the
  // device rotated, `mCurrentAppOrientation` stayed NOSENSOR and the window
  // stayed `port`. That would have broken the mounted case to fix the handheld
  // one.
  //
  // An empty list means "no preference", which resolves to
  // SCREEN_ORIENTATION_UNSPECIFIED and hands the decision back to Android: a
  // phone held upright shows portrait, a phone on a windscreen mount rotates to
  // the wide cluster, and the user's own auto-rotate setting is respected
  // instead of being overridden. Both layouts already exist and are tested
  // (P2 built the portrait one; `dashboard_layout_test` and the goldens cover
  // both), so nothing here is a new surface.
  await SystemChrome.setPreferredOrientations([]);

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
