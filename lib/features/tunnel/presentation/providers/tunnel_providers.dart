import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../distance/presentation/providers/distance_providers.dart';
import '../../../gps/presentation/providers/gps_providers.dart';
import '../../../trip/presentation/providers/trip_providers.dart';
import '../../domain/tunnel_marker.dart';

/// Manual tunnel recording state.
class TunnelState {
  const TunnelState({this.start, this.last});

  /// The open marker — non-null while a tunnel is being recorded.
  final TunnelMark? start;

  /// The most recently completed measurement, kept on screen after the end
  /// marker so the co-driver can read it back.
  final TunnelResult? last;

  bool get recording => start != null;

  static const TunnelState idle = TunnelState();
}

/// Manual rally-style tunnel markers.
///
/// Two roles, deliberately kept distinct:
///
///  1. **Measurement** — snapshot Trip A, speed, wall clock and GPS position at
///     each marker, then report the leg's distance / duration / average speed.
///
///  2. **Override** — while recording, force the distance engine into Tunnel
///     Mode. The driver sees the tunnel mouth before the GPS chip notices
///     anything, so pressing the button starts the sensor estimate immediately
///     rather than waiting out [AppConstants.tunnelConfirmDelay] of degraded
///     fixes. This is the manual source's place in the engine's priority chain.
///
/// Markers read Trip A because that's the counter a co-driver calls distances
/// from, and it already flows through the engine — so a tunnel measured with no
/// GPS at all still has real (estimated) distance in it.
class TunnelController extends Notifier<TunnelState> {
  @override
  TunnelState build() => TunnelState.idle;

  /// Mark the tunnel entrance. No-op if already recording.
  void markStart() {
    if (state.recording) return;

    state = TunnelState(start: _mark(), last: state.last);
    ref.read(distanceEngineProvider.notifier).setManualTunnel(true);
  }

  /// Mark the tunnel exit and compute the result. No-op if not recording.
  void markEnd() {
    final start = state.start;
    if (start == null) return;

    final result = TunnelResult.between(start, _mark());
    state = TunnelState(start: null, last: result);
    ref.read(distanceEngineProvider.notifier).setManualTunnel(false);
  }

  /// Abandon an in-progress recording without producing a result.
  void cancel() {
    if (!state.recording) return;
    state = TunnelState(start: null, last: state.last);
    ref.read(distanceEngineProvider.notifier).setManualTunnel(false);
  }

  /// Snapshot the instruments right now.
  TunnelMark _mark() {
    final gps = ref.read(gpsStateProvider).valueOrNull;
    return TunnelMark(
      at: DateTime.now(),
      distanceMeters: ref.read(tripAProvider),
      // The engine's speed, so a marker placed inside a tunnel records the
      // sensor estimate rather than a stale GPS value.
      speedMps: ref.read(displaySpeedMpsProvider),
      latitude: gps?.latitude ?? 0,
      longitude: gps?.longitude ?? 0,
      hasFix: gps?.hasFix ?? false,
    );
  }
}

final tunnelProvider =
    NotifierProvider<TunnelController, TunnelState>(TunnelController.new);

/// Fine-grained slices so the button doesn't rebuild the result panel.
final tunnelRecordingProvider =
    Provider<bool>((ref) => ref.watch(tunnelProvider.select((s) => s.recording)));

final lastTunnelResultProvider =
    Provider<TunnelResult?>((ref) => ref.watch(tunnelProvider.select((s) => s.last)));
