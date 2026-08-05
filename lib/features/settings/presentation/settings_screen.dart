import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_clock.dart';
import '../../distance/presentation/providers/distance_providers.dart';
import '../../replay/presentation/simulation_provider.dart';
import '../../route_log/domain/route_session.dart';
import '../../route_log/presentation/providers/gpx_providers.dart';
import '../../route_log/presentation/providers/route_log_providers.dart';
import '../../trip/domain/calibration.dart';
import '../../trip/presentation/providers/trip_providers.dart';
import 'providers/settings_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);

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
            Flexible(child: Text('SETTINGS', overflow: TextOverflow.ellipsis)),
          ],
        ),
        backgroundColor: AppColors.base,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionTitle('DISPLAY'),
          _SwitchRow(
            label: 'Night mode',
            value: settings.isNight,
            onChanged: (_) => ctrl.toggleDisplayMode(),
          ),
          _ChoiceRow(
            label: 'Speed unit',
            value: settings.speedUnit.label,
            onTap: ctrl.toggleSpeedUnit,
          ),
          const _SectionTitle('COMPASS'),
          _SwitchRow(
            label: 'Use true north',
            value: settings.useTrueNorth,
            onChanged: (_) => ctrl.toggleTrueNorth(),
          ),
          const _SectionTitle('PERMISSIONS'),
          const _LocationPermissionRow(),
          const _SectionTitle('CALIBRATION'),
          _CalibrationCard(),
          const _SectionTitle('TRIP'),
          _DangerRow(
            label: 'Reset odometer',
            onTap: () => ref.read(tripProvider.notifier).resetOdometer(),
          ),
          // SPEC-v2 §15.3: the automatic record that replaced the manual
          // TUNNEL START / END buttons. Not debug — this is the co-driver's
          // read-back of every stretch the app had to estimate.
          const _SectionTitle('ESTIMATED SECTIONS'),
          _ChoiceRow(
            label: 'Section log',
            value: '${ref.watch(estimatedSectionsProvider).length} recorded',
            onTap: () => context.push('/sections'),
          ),
          const _SectionTitle('ROUTE SESSIONS'),
          _SessionsSection(),
          // SPEC-v2 §20.1's debug-menu option. Debug builds only — this swaps
          // the GPS and motion sources under the whole app, and a rally
          // computer that can be talked into inventing its own position is not
          // a rally computer. kDebugMode is a const, so this whole subtree is
          // compiled out of a release build rather than merely hidden.
          if (kDebugMode) ...[
            const _SectionTitle('DEBUG'),
            _SwitchRow(
              label: 'Simulated drive (tunnel)',
              value: ref.watch(simulationEnabledProvider),
              onChanged: (v) =>
                  ref.read(simulationEnabledProvider.notifier).state = v,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                'Drives the REAL Niayesh Tunnel, Tehran (6 658 m) west to east '
                'at 60 km/h: 60 s approach, then 399 s of genuine GPS silence '
                'between the portals, then 60 s out the far side. Open the map '
                'to watch it enter one portal and leave the other. Trip should '
                'gain about 6.66 km through the dark.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CalibrationCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(calibrationProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final err = Calibration.percentError(factor);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(factor.toStringAsFixed(4),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 34, fontWeight: FontWeight.w700)),
              Text('${err >= 0 ? '+' : ''}${err.toStringAsFixed(2)}%',
                  style: TextStyle(color: err.abs() < 0.01 ? AppColors.ok : AppColors.warn)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Step('-1%', () => ctrl.nudgeCalibration(-0.01)),
              _Step('-0.1%', () => ctrl.nudgeCalibration(-0.001)),
              _Step('+0.1%', () => ctrl.nudgeCalibration(0.001)),
              _Step('+1%', () => ctrl.nudgeCalibration(0.01)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _calibrateByReference(context, ref),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: const BorderSide(color: AppColors.accent),
              ),
              child: const Text('CALIBRATE FROM KNOWN DISTANCE'),
            ),
          ),
        ],
      ),
    );
  }

  /// Drive a known distance, then enter the reference + what the meter read.
  Future<void> _calibrateByReference(BuildContext context, WidgetRef ref) async {
    final refCtl = TextEditingController();
    final measCtl = TextEditingController(
      text: (ref.read(tripAProvider) / 1000).toStringAsFixed(3),
    );

    final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Calibrate', style: TextStyle(color: AppColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: refCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Reference distance (km)'),
            ),
            TextField(
              controller: measCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Meter measured (km)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          TextButton(
            onPressed: () {
              final refKm = double.tryParse(refCtl.text);
              final measKm = double.tryParse(measCtl.text);
              if (refKm == null || measKm == null) {
                Navigator.pop(context);
                return;
              }
              final f = Calibration.factorFromReference(
                measuredMeters: measKm * 1000,
                referenceMeters: refKm * 1000,
                current: ref.read(calibrationProvider),
              );
              Navigator.pop(context, f);
            },
            child: const Text('APPLY'),
          ),
        ],
      ),
    );
    if (result != null) {
      ref.read(settingsProvider.notifier).setCalibration(result);
    }
  }
}

class _Step extends StatelessWidget {
  const _Step(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.divider),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _SessionsSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(savedSessionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () async {
            final imported = await ref.read(gpxImportProvider)();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(imported == null ? 'Import cancelled' : 'Imported ${imported.name}')),
              );
            }
          },
          icon: const Icon(Icons.upload_file),
          label: const Text('IMPORT GPX'),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.info, side: const BorderSide(color: AppColors.info)),
        ),
        const SizedBox(height: 8),
        if (sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('No saved sessions', style: TextStyle(color: AppColors.textDim))),
          )
        else
          ...sessions.map((s) => _SessionTile(session: s)),
      ],
    );
  }
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});
  final RouteSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        title: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${session.points.length} pts · ${Formatters.distance(session.distanceMeters, metric: true)}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.ios_share, color: AppColors.info),
              onPressed: () => ref.read(gpxFileServiceProvider).exportAndShare(session),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              onPressed: () async {
                await ref.read(routeLogRepositoryProvider).delete(session.id);
                // Trigger list refresh.
                ref.invalidate(savedSessionsProvider);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.accent, fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 13)),
      );
}

/// B7 — a way BACK from a denied location permission.
///
/// Before this, tapping DON'T ALLOW left the app permanently dead with no
/// in-app explanation: the rationale screen is shown once and never again, so
/// an accidental deny meant a trip counter that silently never moved. The
/// alternative considered was re-showing the rationale whenever location is
/// missing, which was rejected because it nags the person who denied
/// deliberately. A row they have to come and find does neither.
///
/// Android distinguishes "denied" (askable) from "denied forever" (only the
/// system settings page can undo it), so this checks first and routes to the
/// right one instead of firing a request that the OS would silently swallow.
class _LocationPermissionRow extends ConsumerStatefulWidget {
  const _LocationPermissionRow();

  @override
  ConsumerState<_LocationPermissionRow> createState() =>
      _LocationPermissionRowState();
}

class _LocationPermissionRowState
    extends ConsumerState<_LocationPermissionRow> {
  LocationPermission? _permission;
  bool _serviceOn = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final p = await Geolocator.checkPermission();
    final on = await Geolocator.isLocationServiceEnabled();
    if (!mounted) return;
    setState(() {
      _permission = p;
      _serviceOn = on;
    });
  }

  Future<void> _act() async {
    // Location switched off device-wide: no app-level permission helps.
    if (!_serviceOn) {
      await Geolocator.openLocationSettings();
      await _refresh();
      return;
    }
    if (_permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    } else {
      await Geolocator.requestPermission();
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final granted = _serviceOn &&
        (_permission == LocationPermission.always ||
            _permission == LocationPermission.whileInUse);

    final (String value, Color color) = switch ((granted, _serviceOn)) {
      (true, _) => ('GRANTED', AppColors.ok),
      (false, false) => ('LOCATION OFF', AppColors.danger),
      _ => ('TAP TO GRANT', AppColors.warn),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        title: const Text('Location access'),
        subtitle: granted
            ? null
            : const Text('The trip counter cannot measure without it'),
        trailing: Text(
          value,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w700, fontSize: 13),
        ),
        // Still tappable when granted: it is the honest way to confirm the
        // state, and re-requesting an already-granted permission is a no-op.
        onTap: _act,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
      child: SwitchListTile(
        title: Text(label, style: const TextStyle(color: AppColors.textPrimary)),
        value: value,
        activeColor: AppColors.accent,
        onChanged: onChanged,
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.value, required this.onTap});
  final String label;
  final String value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: AppColors.textPrimary)),
        trailing: Text(value, style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
        onTap: onTap,
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: AppColors.danger)),
        trailing: const Icon(Icons.restart_alt, color: AppColors.danger),
        onTap: onTap,
      ),
    );
  }
}
