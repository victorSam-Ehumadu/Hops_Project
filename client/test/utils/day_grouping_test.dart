// Day grouping is shared by the Action Log, Community Alerts and 1:1 chat,
// so a mistake here is a mistake in three places at once — and it is the
// kind of mistake that only shows up near midnight or at a month boundary,
// which is exactly when nobody is testing.

import 'package:client/utils/day_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSameDay', () {
    test('two times on the same date match however far apart', () {
      // 23 hours apart, same calendar day.
      expect(
          isSameDay(DateTime(2026, 11, 2, 0, 5), DateTime(2026, 11, 2, 23, 5)),
          isTrue);
    });

    test('times minutes apart across midnight do NOT match', () {
      // The case a difference-in-hours check gets wrong: ten minutes
      // apart, two different days.
      expect(
          isSameDay(
              DateTime(2026, 11, 2, 23, 55), DateTime(2026, 11, 3, 0, 5)),
          isFalse);
    });

    test('the same day in different months or years does not match', () {
      expect(isSameDay(DateTime(2026, 10, 2), DateTime(2026, 11, 2)), isFalse);
      expect(isSameDay(DateTime(2025, 11, 2), DateTime(2026, 11, 2)), isFalse);
    });
  });

  group('dayLabel', () {
    final now = DateTime(2026, 11, 2, 14, 0); // a Monday

    test('today and yesterday are named, not dated', () {
      expect(dayLabel(DateTime(2026, 11, 2, 1, 0), now: now), 'Today');
      expect(dayLabel(DateTime(2026, 11, 1, 23, 0), now: now), 'Yesterday');
    });

    test('yesterday is a calendar day, not 24 hours', () {
      // 15 hours before "now" but on the previous date.
      expect(dayLabel(DateTime(2026, 11, 1, 23, 0), now: now), 'Yesterday');
      // 13 hours before "now" and still today.
      expect(dayLabel(DateTime(2026, 11, 2, 1, 0), now: now), 'Today');
    });

    test('the rest of the past week is the weekday name', () {
      expect(dayLabel(DateTime(2026, 10, 31), now: now), 'Saturday');
      expect(dayLabel(DateTime(2026, 10, 28), now: now), 'Wednesday');
    });

    test('seven days back is a date, not a weekday', () {
      // Otherwise "Monday" would be ambiguous between this week and last.
      expect(dayLabel(DateTime(2026, 10, 26), now: now), '26 October');
    });

    test('an earlier year carries the year', () {
      expect(dayLabel(DateTime(2025, 10, 26), now: now), '26 October 2025');
    });

    test('a date in the current year omits the year', () {
      expect(dayLabel(DateTime(2026, 1, 9), now: now), '9 January');
    });

    test('month boundaries do not confuse yesterday', () {
      final firstOfMonth = DateTime(2026, 11, 1, 9, 0);
      expect(dayLabel(DateTime(2026, 10, 31, 22, 0), now: firstOfMonth),
          'Yesterday');
    });

    test('year boundaries do not confuse yesterday', () {
      final newYear = DateTime(2027, 1, 1, 9, 0);
      expect(
          dayLabel(DateTime(2026, 12, 31, 22, 0), now: newYear), 'Yesterday');
    });
  });
}
