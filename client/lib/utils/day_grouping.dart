// lib/utils/day_grouping.dart
//
// Shared "which day was this?" helpers and the divider that announces a new
// one, for every list that reads as a timeline: the Action Log, Community
// Alerts and 1:1 chat.
//
// One implementation rather than three, because the alternative is three
// screens that disagree about where a day starts — and a chat that says
// "Yesterday" next to a log that says the date for the same message is the
// kind of thing nobody reports and everybody distrusts.
//
// Deliberately hand-rolled rather than pulled from `intl`: this needs five
// labels and a comparison, the project doesn't depend on intl today, and
// adding a dependency for that would cost more than it saves. The
// trade-off is that month and weekday names are English-only — fine for a
// single-campus app whose entire UI is already English.

import 'package:flutter/material.dart';

const List<String> _kMonths = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

const List<String> _kWeekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday',
  'Friday', 'Saturday', 'Sunday',
];

/// True when [a] and [b] fall on the same calendar day.
///
/// Compares the date parts rather than the difference between the two
/// instants: two timestamps eight hours apart can be on different days,
/// and two timestamps twenty hours apart can be on the same one, so
/// anything built on `difference(...).inDays` gets this wrong twice a day.
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// A human label for the day [when] falls on, relative to [now].
///
/// "Today" / "Yesterday" for the two days people actually think of by
/// name, the weekday for the rest of the past week (far easier to place
/// than a bare date), then the date itself. The year is only shown once it
/// is not the current one, which keeps the common case short.
String dayLabel(DateTime when, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final local = when.toLocal();
  if (isSameDay(local, today)) return 'Today';

  final yesterday = DateTime(today.year, today.month, today.day)
      .subtract(const Duration(days: 1));
  if (isSameDay(local, yesterday)) return 'Yesterday';

  // Midnight-to-midnight, so "6 days ago" means six calendar days rather
  // than 144 hours.
  final startOfToday = DateTime(today.year, today.month, today.day);
  final startOfThatDay = DateTime(local.year, local.month, local.day);
  final daysBack = startOfToday.difference(startOfThatDay).inDays;
  if (daysBack > 0 && daysBack < 7) return _kWeekdays[local.weekday - 1];

  final month = _kMonths[local.month - 1];
  if (local.year == today.year) return '${local.day} $month';
  return '${local.day} $month ${local.year}';
}

/// The divider that introduces a new day in a timeline.
///
/// A centred label on a hairline rather than a heading, so it separates
/// without competing with the content either side of it.
class DaySeparator extends StatelessWidget {
  final String label;
  final EdgeInsetsGeometry padding;

  const DaySeparator({
    super.key,
    required this.label,
    this.padding = const EdgeInsets.symmetric(vertical: 14),
  });

  /// Builds one straight from a timestamp.
  factory DaySeparator.forDate(DateTime when, {DateTime? now, Key? key}) =>
      DaySeparator(key: key, label: dayLabel(when, now: now));

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final line = colors.onSurface.withValues(alpha: 0.12);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Divider(color: line, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
                color: colors.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          Expanded(child: Divider(color: line, height: 1)),
        ],
      ),
    );
  }
}
