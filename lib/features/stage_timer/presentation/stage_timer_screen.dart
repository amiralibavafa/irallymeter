import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_clock.dart';
import '../domain/stage_timer_state.dart' show TimerMode, CountdownTarget;
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
              // The countdown target is only adjustable while stopped: changing
              // it mid-run would move the finish line under a crew already
              // counting down to it.
              if (isCountdown)
                _CountdownAdjust(
                  target: state.countdownTarget,
                  enabled: !state.running,
                  onChanged: ctrl.setCountdownTarget,
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

/// Sets the countdown target. `setCountdownTarget` existed on the controller
/// from the start but nothing ever called it, so the countdown was frozen at
/// its 1:00 default and the mode was effectively a fixed one-minute timer.
///
/// Stepped buttons rather than a wheel picker: this is used in a moving car
/// with gloves on, where a scroll picker is unusable. The steps are the ones a
/// road book actually uses, minutes for the start interval and ten seconds for
/// trimming it.
class _CountdownAdjust extends StatelessWidget {
  const _CountdownAdjust({
    required this.target,
    required this.enabled,
    required this.onChanged,
  });

  final Duration target;
  final bool enabled;
  final ValueChanged<Duration> onChanged;


  /// Type an exact target as `m:ss` or `mm:ss`. Parsed and clamped by the same
  /// rules as the steppers, so there is exactly one definition of a legal
  /// target rather than one per entry method.
  Future<void> _promptForTarget(BuildContext context) async {
    // PRE-SELECTED, not just pre-filled. Pre-filling alone was a trap I walked
    // into testing this: the cursor lands after "1:00", so typing "4:30" gives
    // "1:004:30", which the parser correctly refuses — and the user sees a
    // dialog close with nothing changed and no idea why. Selecting the whole
    // value means the first keystroke replaces it, which is what anyone
    // retyping a time expects.
    final controller = TextEditingController(
      text: '${target.inMinutes}:'
          '${(target.inSeconds % 60).toString().padLeft(2, '0')}',
    );
    controller.selection =
        TextSelection(baseOffset: 0, extentOffset: controller.text.length);

    final picked = await showDialog<Duration>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final parsed = CountdownTarget.parse(controller.text);
          final valid = parsed != null;
          return AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text('COUNTDOWN TARGET'),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.datetime,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              onChanged: (_) => setLocal(() {}),
              decoration: InputDecoration(
                hintText: 'm:ss',
                helperText: 'minutes:seconds, e.g. 4:30',
                // Says WHY rather than failing quietly. Before this, an
                // unparseable entry closed the dialog and changed nothing,
                // which reads as the app ignoring you.
                errorText: valid ? null : 'not a time',
              ),
              onSubmitted: (v) {
                final d = CountdownTarget.parse(v);
                if (d != null) Navigator.of(ctx).pop(d);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('CANCEL'),
              ),
              TextButton(
                // Disabled rather than silently no-op, so the dialog can never
                // close having quietly discarded what was typed.
                onPressed: valid ? () => Navigator.of(ctx).pop(parsed) : null,
                child: const Text('SET'),
              ),
            ],
          );
        },
      ),
    );
    if (picked != null) onChanged(CountdownTarget.clamp(picked));
  }

  @override
  Widget build(BuildContext context) {
    // Clamped so the target can never reach zero or negative, which would make
    // the countdown finish the instant it started.
    void step(Duration by) => onChanged(CountdownTarget.clamp(target + by));

    Widget chip(String label, Duration by) {
      final atLimit = by.isNegative
          ? target <= CountdownTarget.min
          : target >= CountdownTarget.max;
      final on = enabled && !atLimit;
      return Expanded(
        child: GestureDetector(
          onTap: on ? () => step(by) : null,
          child: Container(
            height: 48,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: on ? AppColors.accent : AppColors.divider,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: on ? AppColors.accent : AppColors.textDim,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          // Tap to TYPE an exact time. The steppers cover "a bit more, a bit
          // less" with gloves on; typing covers "the road book says 4:30" and
          // is the only sane way to reach a far-off value, which by steps is
          // dozens of taps.
          GestureDetector(
            onTap: enabled ? () => _promptForTarget(context) : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                enabled
                    ? 'TARGET ${Formatters.stopwatch(target)} · TAP TO EDIT'
                    : 'TARGET ${Formatters.stopwatch(target)} · LOCKED WHILE RUNNING',
                style: TextStyle(
                  color: enabled ? AppColors.accent : AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            chip('-1:00', const Duration(minutes: -1)),
            chip('-0:10', const Duration(seconds: -10)),
            chip('+0:10', const Duration(seconds: 10)),
            chip('+1:00', const Duration(minutes: 1)),
          ]),
        ],
      ),
    );
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
