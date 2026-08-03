# iRallyMeter

A rally-grade co-driver tool: real-time GPS speedometer, trip computer (A/B +
odometer), compass/CAP heading, stage timer, live map and GPX route logging.
Built for reliability and sunlight legibility under racing conditions.

## Stack

Flutter • Riverpod (state + DI) • GoRouter • Hive (no-codegen storage) •
geolocator • flutter_map • sensors_plus • permission_handler.

## Architecture

Feature-first **clean architecture**. Each feature has three layers:

```
lib/
  core/                     # cross-cutting: theme, router, storage, utils, DI
    constants/              # tuning knobs (filter strength, GPS rate, …)
    di/providers.dart       # root storageProvider (overridden in main)
    storage/                # Hive wrapper + keys (primitives + JSON, no adapters)
    theme/                  # instrument palette, day/night theme extension
    utils/                  # geo math, formatters
  features/
    gps/        data ▸ geolocator service   domain ▸ sample/state/repo   presentation ▸ providers
    trip/       data ▸ repository            domain ▸ state/calibration   presentation ▸ providers + widgets
    compass/    data ▸ sensor fusion         presentation ▸ providers
    stage_timer/domain ▸ state               presentation ▸ providers + screen
    route_log/  data ▸ repo/gpx codec+files  domain ▸ session             presentation ▸ providers
    map/        presentation ▸ screen
    settings/   data ▸ repository            domain ▸ state               presentation ▸ providers + screen
    dashboard/  presentation ▸ screen + widgets
```

- **Domain** is pure Dart (no plugin imports) → unit-testable.
- **Data** implements domain repository interfaces over plugins (`GpsRepository`
  ← `GeolocatorGpsService`) — swappable for mocks/replay.
- **Presentation** = Riverpod providers + widgets.

## Performance design

- **One GPS source, fine-grained slices.** `gpsStateProvider` smooths once per
  fix; widgets `ref.watch(provider.select(...))` only the field they render.
  The speed widget selects the *integer* km/h so sub-unit jitter never repaints.
- **Raw vs processed streams.** Trip/route integrators listen to the *raw*
  stream; the display reads the *smoothed* one — separation of concerns.
- **EMA filtering** on speed + heading (wrap-aware) kills GPS jitter.
- **Throttled persistence** (≤ every 5 s + on edits/dispose) saves flash/battery.
- **Wall-clock timers** so the stage timer survives backgrounding.
- Background GPS via an Android **foreground service** (configured in the
  geolocator `AndroidSettings`).

## Run

```bash
flutter pub get
flutter run            # Android device with GPS
flutter test           # domain unit tests
```

Offline maps: swap the `TileLayer` source in `features/map/.../map_screen.dart`
for a `FileTileProvider`/MBTiles pack — the rest is unchanged.
