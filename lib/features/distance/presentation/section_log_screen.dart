import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_clock.dart';
import '../domain/estimated_section.dart';
import 'providers/distance_providers.dart';

/// SPEC-v2 §15.3 — the automatic log, made visible.
///
/// §15 deleted the manual TUNNEL START / TUNNEL END buttons, and §15.3 replaces
/// what they produced: "Every estimated section is recorded automatically
/// without user action … This gives the user the same information the manual
/// buttons would have provided, but measured rather than hand-triggered."
///
/// The engine has recorded these since `[3.4c]`; until now nothing showed them,
/// so the second half of that sentence was unmet — the co-driver had strictly
/// less information than the buttons used to give them.
class SectionLogScreen extends ConsumerWidget {
  const SectionLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(estimatedSectionsProvider);

    return Scaffold(
      backgroundColor: AppColors.base,
      appBar: AppBar(
        backgroundColor: AppColors.base,
        // Short title on purpose: "ESTIMATED SECTIONS" beside the clock
        // overflowed the app bar at 1080x2400, which is the same mistake the
        // dashboard top bar already makes. Not repeating it here.
        title: const Row(
          children: [
            AppClock(),
            SizedBox(width: 12),
            Text('SECTIONS',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2)),
          ],
        ),
      ),
      body: sections.isEmpty
          ? const _Empty()
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              // Newest first: the section a co-driver questions is the one they
              // just drove through.
              itemCount: sections.length,
              itemBuilder: (_, i) =>
                  _SectionCard(section: sections[sections.length - 1 - i],
                      index: sections.length - i),
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No estimated sections yet.\n\n'
            'One is recorded automatically every time GNSS is lost and '
            'recovered — no button to press.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, height: 1.5),
          ),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, required this.index});

  final EstimatedSection section;
  final int index;

  @override
  Widget build(BuildContext context) {
    // §16.1's "flag the event in the trip log" — a correction big enough to
    // need the slow window is the one worth a second look.
    final flagged = section.largeCorrection;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: flagged
            ? Border.all(color: AppColors.warn, width: 1.5)
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('#$index',
                  style: const TextStyle(
                      color: AppColors.accent, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Text(
                '${_hhmmss(section.start)} → ${_hhmmss(section.end)}',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const Spacer(),
              if (flagged)
                const Text('LARGE',
                    style: TextStyle(
                        color: AppColors.warn,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Field(
                  label: 'DURATION',
                  value: Formatters.legTime(section.duration)),
              _Field(
                  label: 'ESTIMATED',
                  value: Formatters.distance(section.estimatedMeters,
                      metric: true)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // §15.3 names this explicitly: "the speed that was held".
              _Field(
                  label: 'HELD',
                  value:
                      '${(section.heldSpeedMps * 3.6).toStringAsFixed(0)} km/h'),
              _Field(
                label: 'CORRECTION',
                value: section.uncorrected
                    ? '—'
                    : '+${section.correctionMeters.toStringAsFixed(0)} m',
                hint: section.uncorrected
                    ? 'nothing provable on recovery'
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _hhmmss(DateTime t) => Formatters.clock(t);
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    letterSpacing: 1.1)),
            const SizedBox(height: 2),
            Text(value,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            if (hint != null)
              Text(hint!,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 10)),
          ],
        ),
      );
}
