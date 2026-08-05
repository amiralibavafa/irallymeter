// The countdown target parser.
//
// This code stands between a typo and a crew's countdown finishing the instant
// it starts, so it is tested rather than eyeballed. It was originally a private
// static inside the dialog, which is exactly why it could not be tested — the
// extraction into the domain was the fix.
//
// The rule everything here checks: WHEN IN DOUBT, RETURN NULL. The caller
// leaves the existing target alone, so an unparseable entry is a no-op rather
// than a silent, wrong countdown.

import 'package:flutter_test/flutter_test.dart';
import 'package:irallymeter/features/stage_timer/domain/stage_timer_state.dart';

void main() {
  group('COUNTDOWN TARGET · parse', () {
    test('01 · m:ss is read as minutes and seconds', () {
      expect(CountdownTarget.parse('4:30'),
          const Duration(minutes: 4, seconds: 30));
      expect(CountdownTarget.parse('12:05'),
          const Duration(minutes: 12, seconds: 5));
      expect(CountdownTarget.parse('0:45'), const Duration(seconds: 45));
    });

    test('02 · surrounding whitespace is tolerated', () {
      expect(CountdownTarget.parse('  3:00 '), const Duration(minutes: 3));
    });

    test('03 · a bare number is SECONDS, not minutes', () {
      // Someone typing "90" into a stage timer means a minute and a half, and
      // reading it as 90 minutes would be off by a factor of sixty.
      expect(CountdownTarget.parse('90'), const Duration(seconds: 90));
    });

    test('04 · seconds above 59 are REJECTED, not carried', () {
      expect(CountdownTarget.parse('4:75'), isNull,
          reason: '"4:75" is a typo, not a request for 5:15 — carrying it '
              'would silently set a target nobody asked for');
      expect(CountdownTarget.parse('4:60'), isNull);
    });

    test('05 · garbage returns null so the existing target survives', () {
      for (final bad in ['', '   ', 'abc', '4:', ':30', '1:2:3', '4:ab', '-']) {
        expect(CountdownTarget.parse(bad), isNull,
            reason: '"$bad" must not resolve to a duration');
      }
    });

    test('06 · negative values are rejected', () {
      expect(CountdownTarget.parse('-5'), isNull);
      expect(CountdownTarget.parse('-1:30'), isNull);
    });
  });

  group('COUNTDOWN TARGET · clamp', () {
    test('07 · below the floor is raised to it', () {
      // A target of zero finishes the instant it starts, which reads as the
      // timer being broken.
      expect(CountdownTarget.clamp(Duration.zero), CountdownTarget.min);
      expect(CountdownTarget.clamp(const Duration(seconds: 3)),
          CountdownTarget.min);
    });

    test('08 · above the ceiling is lowered to it', () {
      expect(CountdownTarget.clamp(const Duration(hours: 5)),
          CountdownTarget.max);
    });

    test('09 · a legal value passes through untouched', () {
      const ok = Duration(minutes: 4, seconds: 30);
      expect(CountdownTarget.clamp(ok), ok);
    });

    test('10 · typed and stepped entry share ONE definition of legal', () {
      // Both paths go through clamp, so a value reachable by typing is
      // reachable by stepping and vice versa. Two definitions would drift.
      final typed = CountdownTarget.clamp(CountdownTarget.parse('0:05')!);
      final stepped = CountdownTarget.clamp(
          CountdownTarget.min - const Duration(seconds: 5));
      expect(typed, stepped);
      expect(typed, CountdownTarget.min);
    });
  });
}
