import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/di/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/average_speed/presentation/providers/average_speed_providers.dart';
import 'features/distance/presentation/providers/distance_providers.dart';
import 'features/gps/presentation/providers/gps_providers.dart';
import 'features/settings/presentation/providers/settings_providers.dart';
import 'features/trip/presentation/providers/trip_providers.dart';

class IRallyMeterApp extends ConsumerWidget {
  const IRallyMeterApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Theme follows the persisted day/night display mode.
    final mode = ref.watch(settingsProvider.select((s) => s.displayMode));

    // Eagerly start the GPS engine and trip integrator at app root so trip
    // distance accumulates regardless of which screen is showing. Watching
    // here keeps these providers alive for the whole app lifetime.
    //
    // Held back until the rationale screen is done (P3): `positionStream()`
    // raises the system location dialog on its own, so starting it here would
    // put the cold prompt on top of the screen meant to explain it. This flips
    // exactly once, false → true, and never back.
    if (ref.watch(onboardedProvider)) {
      ref.watch(rawGpsStreamProvider);
      ref.watch(gpsStateProvider);
      // The distance engine must run app-wide too: it owns tunnel detection,
      // and a tunnel entered while the map or stage timer is showing has to be
      // caught just the same. Watching the delta stream (not just the engine)
      // keeps the increments flowing to the trip/average integrators below.
      ref.watch(distanceEngineProvider);
      ref.watch(distanceDeltaProvider);
      ref.watch(tripProvider);
      // Accumulate average speed app-wide too, so it keeps integrating no
      // matter which screen is showing.
      ref.watch(averageSpeedProvider);
    }

    return MaterialApp.router(
      title: 'iRallyMeter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(mode),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
