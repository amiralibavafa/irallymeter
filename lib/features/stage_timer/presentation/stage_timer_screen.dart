import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_clock.dart';
import '../domain/stage_timer_state.dart' show TimerMode;
import 'providers/stage_timer_providers.dart';

class StageTimerScreen extends ConsumerWidget {
  const StageTimerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(stageTimerProvider);
    final ctrl = ref.read(stageTimerProvider.notifier);
    final colors = InstrumentColors.of(context);

    // Tick only while running; recompute display from wall clock.
    final now = ref.watch(timerTickProvider).valueOrNull ?? DateTime.now();
    final isCountdown = state.mode == TimerMode.countdown;
    final shown = isCountdown ? state.remaining(now) : state.elapsed(now);
    final overrun = isCountdown && shown.isNegative;

    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [AppClock(), SizedBox(width: 12), Text('STAGE TIMER')],
        ),
        backgroundColor: AppColors.base,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _ModeToggle(mode: state.mode, running: state.running, onChanged: ctrl.setMode),
              const SizedBox(height: 8),
              Expanded(
                flex: 3,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Formatters.stopwatch(shown),
                      style: Theme.of(context).textTheme.displayMedium?.copyWith(
                            color: overrun ? AppColors.danger : colors.primary,
                          ),
                    ),
                  ),
                ),
              ),
              _Controls(running: state.running, ctrl: ctrl),
              const SizedBox(height: 12),
              Expanded(flex: 2, child: _Splits(splits: state.splits)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.running, required this.onChanged});
  final TimerMode mode;
  final bool running;
  final ValueChanged<TimerMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, TimerMode m) {
      final sel = m == mode;
      return Expanded(
        child: GestureDetector(
          onTap: running ? null : () => onChanged(m),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sel ? AppColors.accent : AppColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(label,
                style: TextStyle(
                  color: sel ? Colors.black : AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                )),
          ),
        ),
      );
    }

    return Row(children: [
      seg('STOPWATCH', TimerMode.stopwatch),
      const SizedBox(width: 8),
      seg('COUNTDOWN', TimerMode.countdown),
    ]);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.running, required this.ctrl});
  final bool running;
  final StageTimerController ctrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _BigButton(
          label: running ? 'PAUSE' : 'START',
          color: running ? AppColors.warn : AppColors.ok,
          onTap: ctrl.toggle,
        ),
        const SizedBox(width: 10),
        _BigButton(label: 'SPLIT', color: AppColors.info, onTap: running ? ctrl.split : null),
        const SizedBox(width: 10),
        _BigButton(label: 'RESET', color: AppColors.danger, onTap: ctrl.reset),
      ],
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.color, this.onTap});
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Expanded(
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: enabled ? color : AppColors.divider, width: 2),
            ),
            child: Text(label,
                style: TextStyle(
                  color: enabled ? color : AppColors.textDim,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                )),
          ),
        ),
      ),
    );
  }
}

class _Splits extends StatelessWidget {
  const _Splits({required this.splits});
  final List<Duration> splits;

  @override
  Widget build(BuildContext context) {
    if (splits.isEmpty) {
      return const Center(
        child: Text('NO SPLITS', style: TextStyle(color: AppColors.textDim, letterSpacing: 2)),
      );
    }
    return ListView.builder(
      reverse: true,
      itemCount: splits.length,
      itemBuilder: (context, i) {
        final n = i + 1;
        final prev = i == 0 ? Duration.zero : splits[i - 1];
        final delta = splits[i] - prev;
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('SPLIT $n', style: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
              Text('+${Formatters.stopwatch(delta)}', style: const TextStyle(color: AppColors.info)),
              Text(Formatters.stopwatch(splits[i]),
                  style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700)),
            ],
          ),
        );
      },
    );
  }
}
