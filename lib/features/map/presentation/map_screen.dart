import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_clock.dart';
// The compass instrument lives with the dashboard widgets; it is reused here so
// the heading readout now appears on the map instead of the home cluster.
import '../../dashboard/presentation/widgets/heading_display.dart';
import '../../gps/presentation/providers/gps_providers.dart';
import '../../route_log/presentation/providers/route_log_providers.dart';

/// Live map with route polyline and a heading-aware position marker.
///
/// Offline maps: point the [TileLayer] at a local source (e.g. an MBTiles
/// file via a custom TileProvider, or `FileTileProvider` over a pre-seeded
/// `{z}/{x}/{y}.png` cache). The online OSM source below is the default; swap
/// `urlTemplate`/`tileProvider` for your offline pack — the rest is unchanged.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final MapController _controller = MapController();
  bool _follow = true;

  /// Latched once any tile fails. Latched rather than transient on purpose: if
  /// tiles are failing they will keep failing until the network or the tile
  /// source changes, and a banner that flickers on every retry is worse than
  /// one that states the situation and stays put.
  bool _tilesFailed = false;



  @override
  Widget build(BuildContext context) {
    final gps = ref.watch(gpsStateProvider).valueOrNull;
    final recording = ref.watch(routeRecorderProvider);

    final hasPos = gps != null && gps.hasFix;
    final pos = hasPos ? LatLng(gps.latitude, gps.longitude) : const LatLng(0, 0);

    // Keep the camera on the vehicle when following.
    if (_follow && hasPos) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.move(pos, _controller.camera.zoom);
      });
    }

    final track = recording.points.map((p) => LatLng(p.lat, p.lon)).toList();

    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            AppClock(),
            SizedBox(width: 12),
            // Same reason as the stage timer: the clock is the
            // instrument, the word is a label, so the label yields
            // rather than overflowing on a narrow phone.
            Flexible(child: Text('MAP', overflow: TextOverflow.ellipsis)),
          ],
        ),
        backgroundColor: AppColors.base,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              // flutter_map defaults this to 0xFFE0E0E0 — a light grey. In an
              // app that is black on every other screen, an unloaded map threw
              // a large pale panel at a driver whose eyes are adapted to a dark
              // cockpit. It also made "tiles failed" look identical to "empty
              // terrain". Matching AppColors.base fixes both.
              backgroundColor: AppColors.base,
              initialCenter: hasPos ? pos : const LatLng(46.0, 8.0),
              initialZoom: 15,
              maxZoom: 19,
              minZoom: 3,
              // Any manual gesture breaks "follow" so the user can pan freely.
              onPointerDown: (_, __) => setState(() => _follow = false),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // The OSMF tile usage policy requires "a clear, unique User-Agent
                // string that names your app". This said
                // 'com.irallymeter.app', which is not this app's ID and
                // therefore names an application that does not exist.
                userAgentPackageName: 'com.irallyclub.irallymeter',
                // tileProvider: FileTileProvider(), // ← enable for offline packs
                //
                // Fires when a tile request FAILS loudly (404, refused, DNS).
                //
                // It does NOT cover the case that matters most out here: a
                // request that simply never completes, which is what a phone
                // with no data actually does. Verified on device with wifi and
                // mobile data both off — no error callback arrives, the tiles
                // just never appear. A proper offline indicator needs the tile
                // SOURCE decided first (question B2), because the answer
                // differs for a bundled pack versus a live server; the honest
                // interim behaviour is the dark background above, which at
                // least stops a blank map blinding the driver at night.
                errorTileCallback: (_, __, ___) {
                  if (!_tilesFailed && mounted) {
                    setState(() => _tilesFailed = true);
                  }
                },
              ),
              if (track.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(points: track, strokeWidth: 5, color: AppColors.accent),
                  ],
                ),
              if (hasPos)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: pos,
                      width: 44,
                      height: 44,
                      child: _HeadingMarker(
                        headingDeg: gps.headingDeg.isFinite ? gps.headingDeg : 0,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          // Sits ABOVE the coordinate bar and INSIDE the same insets it uses.
          //
          // Every other edge of this map is already occupied: REC badge top
          // left, compass top right, FAB column bottom right. A banner at the
          // top ran under the compass; one spanning the full width at the
          // bottom ran under the FABs. `right: 84` is the coordinate bar's own
          // clearance for that FAB column, so matching it is the fix that
          // stays correct if the buttons move.
          if (_tilesFailed)
            Positioned(
              left: 12,
              right: 84,
              bottom: 64,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.warn),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off, color: AppColors.warn, size: 18),
                      SizedBox(width: 10),
                      // Flexible so a narrow phone wraps the sentence instead
                      // of clipping it. A warning that loses its second half
                      // is worse than no warning, because the half that
                      // survives here is the alarming one.
                      Flexible(
                        child: Text(
                          'MAP TILES UNAVAILABLE  ·  POSITION STILL TRACKING',
                          style: TextStyle(
                            color: AppColors.warn,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (recording.recording)
            const Positioned(top: 12, left: 12, child: _RecBadge()),
          // CAP heading instrument, relocated here from the home cluster.
          const Positioned(
            top: 12,
            right: 12,
            child: SizedBox(width: 200, child: HeadingDisplay()),
          ),
          // Live position readout pinned to the bottom of the map.
          const Positioned(
            left: 12,
            right: 84,
            bottom: 12,
            child: _CoordinateBar(),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              children: [
                _MapFab(
                  icon: _follow ? Icons.gps_fixed : Icons.gps_not_fixed,
                  color: _follow ? AppColors.ok : AppColors.textSecondary,
                  onTap: () => setState(() => _follow = true),
                ),
                const SizedBox(height: 10),
                _RecordButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeadingMarker extends StatelessWidget {
  const _HeadingMarker({required this.headingDeg});
  final double headingDeg;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: headingDeg * math.pi / 180.0,
      child: const Icon(Icons.navigation, color: AppColors.accent, size: 40),
    );
  }
}

class _RecordButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(routeRecorderProvider.select((s) => s.recording));
    final recorder = ref.read(routeRecorderProvider.notifier);
    return _MapFab(
      icon: recording ? Icons.stop : Icons.fiber_manual_record,
      color: recording ? AppColors.textPrimary : AppColors.danger,
      background: recording ? AppColors.danger : null,
      onTap: () async {
        if (recording) {
          final session = await recorder.stopAndSave();
          if (context.mounted && session != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Saved ${session.points.length} points')),
            );
          }
        } else {
          recorder.start();
        }
      },
    );
  }
}

class _MapFab extends StatelessWidget {
  const _MapFab({required this.icon, required this.onTap, this.color, this.background});
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background ?? AppColors.surfaceRaised,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Icon(icon, color: color ?? AppColors.textPrimary, size: 26),
        ),
      ),
    );
  }
}

/// Bottom-of-map readout of the live GPS latitude, longitude and altitude.
/// Watches [gpsStateProvider] directly so it refreshes in real time on every
/// fix, independent of the rest of the map.
class _CoordinateBar extends ConsumerWidget {
  const _CoordinateBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gps = ref.watch(gpsStateProvider).valueOrNull;
    final hasFix = gps != null && gps.hasFix;

    String fmt(double v, int dp) => hasFix ? v.toStringAsFixed(dp) : '--';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Expanded(child: _CoordField(label: 'LAT', value: fmt(gps?.latitude ?? 0, 5))),
          Expanded(child: _CoordField(label: 'LON', value: fmt(gps?.longitude ?? 0, 5))),
          Expanded(
            child: _CoordField(
              label: 'ALT',
              value: hasFix ? '${(gps.altitudeM).toStringAsFixed(0)} m' : '--',
            ),
          ),
        ],
      ),
    );
  }
}

class _CoordField extends StatelessWidget {
  const _CoordField({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _RecBadge extends StatelessWidget {
  const _RecBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
          SizedBox(width: 6),
          Text('REC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}
