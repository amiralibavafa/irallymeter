import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/stage_timer_state.dart';

/// Stage timer controller. Holds anchors only; the displayed value is computed
/// from wall-clock time, so it never drifts and survives backgrounding.
class StageTimerController extends Notifier<StageTimerState> {
  @override
  StageTimerState build() => StageTimerState.initial;

  void setMode(TimerMode mode) {
    if (state.running) return; // don't switch mode mid-run
    state = state.copyWith(mode: mode);
  }

  void setCountdownTarget(Duration target) {
    if (state.running) return;
    state = state.copyWith(countdownTarget: target);
  }

  void start() {
    if (state.running) return;
    state = state.copyWith(running: true, startedAt: DateTime.now());
  }

  void pause() {
    if (!state.running) return;
    final now = DateTime.now();
    state = state.copyWith(
      running: false,
      accumulated: state.elapsed(now),
      clearStartedAt: true,
    );
  }

  void toggle() => state.running ? pause() : start();

  /// Record a split (lap). Captured against current elapsed time.
  void split() {
    if (!state.running) return;
    final e = state.elapsed(DateTime.now());
    state = state.copyWith(splits: [...state.splits, e]);
  }

  void reset() {
    state = state.copyWith(
      running: false,
      accumulated: Duration.zero,
      clearStartedAt: true,
      splits: const [],
    );
  }
}

final stageTimerProvider =
    NotifierProvider<StageTimerController, StageTimerState>(StageTimerController.new);

/// 100 ms UI ticker. Only widgets that render the running time watch this, so
/// the rest of the app isn't rebuilt 10×/second. Emits only while running.
final timerTickProvider = StreamProvider.autoDispose<DateTime>((ref) {
  final running = ref.watch(stageTimerProvider.select((s) => s.running));
  if (!running) {
    return const Stream.empty();
  }
  return Stream<DateTime>.periodic(
    const Duration(milliseconds: 100),
    (_) => DateTime.now(),
  );
});
