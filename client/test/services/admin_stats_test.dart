// Date-window arithmetic and CSV export for the admin statistics view.
//
// The fetch itself needs a live Supabase and is not covered here. What is
// covered is the part that is pure logic and historically gets quietly
// wrong: range boundaries, bucket choice, and CSV quoting.
import 'package:flutter_test/flutter_test.dart';

import 'package:client/services/admin_stats_service.dart';

void main() {
  group('preset windows', () {
    test('each preset spans the duration it claims', () {
      final h24 = StatsWindow.preset(StatsRange.last24h);
      expect(h24.to.difference(h24.from).inHours, 24);

      final d7 = StatsWindow.preset(StatsRange.last7d);
      expect(d7.to.difference(d7.from).inDays, 7);

      final d30 = StatsWindow.preset(StatsRange.last30d);
      expect(d30.to.difference(d30.from).inDays, 30);
    });

    test('never ends in the future', () {
      // A window running past now produces empty trailing buckets, which
      // on a chart read as activity suddenly collapsing to zero.
      final now = DateTime.now().toUtc();
      for (final kind in StatsRange.values) {
        final w = StatsWindow.preset(kind);
        expect(w.to.isAfter(now.add(const Duration(seconds: 5))), isFalse,
            reason: 'window ends in the future');
      }
    });

    test('from is always before to', () {
      // The server rejects an inverted range with invalid_range, so this
      // would be a user-visible error rather than an empty chart.
      for (final kind in StatsRange.values) {
        final w = StatsWindow.preset(kind);
        expect(w.from.isBefore(w.to), isTrue, reason: 'window inverted');
      }
    });
  });

  group('custom window', () {
    test('includes the whole of the end day', () {
      // The off-by-one this exists to prevent: picking 1st to 7th and
      // getting only up to the 7th at 00:00 silently drops a day of data,
      // which nobody checks because the chart still looks plausible.
      final w = StatsWindow.custom(DateTime(2026, 3, 1), DateTime(2026, 3, 7));
      final end = w.to.toLocal();
      expect(end.day, 7);
      expect(end.hour, 23);
      expect(end.minute, 59);
    });

    test('starts at the beginning of the start day', () {
      final w = StatsWindow.custom(
          DateTime(2026, 3, 1, 15, 30), DateTime(2026, 3, 7));
      final start = w.from.toLocal();
      expect(start.day, 1);
      expect(start.hour, 0);
      expect(start.minute, 0);
    });

    test('a single day is a valid, non-empty range', () {
      final w = StatsWindow.custom(DateTime(2026, 3, 4), DateTime(2026, 3, 4));
      expect(w.from.isBefore(w.to), isTrue,
          reason: 'one day must not collapse to an empty range');
      expect(w.to.difference(w.from).inHours, greaterThanOrEqualTo(23));
    });

    test('is labelled with both dates', () {
      final w = StatsWindow.custom(DateTime(2026, 3, 1), DateTime(2026, 3, 7));
      expect(w.label, contains('01/03/2026'));
      expect(w.label, contains('07/03/2026'));
    });
  });

  group('bucket selection', () {
    test('short windows bucket hourly', () {
      expect(StatsWindow.preset(StatsRange.last24h).bucket, 'hour');
    });

    test('long windows bucket daily', () {
      // Hourly over 30 days is 720 points, unreadable on a phone.
      expect(StatsWindow.preset(StatsRange.last7d).bucket, 'day');
      expect(StatsWindow.preset(StatsRange.last30d).bucket, 'day');
    });

    test('only ever hour or day', () {
      // The server rejects anything else with invalid_bucket rather than
      // defaulting, so an unexpected value here is a hard failure.
      for (final kind in StatsRange.values) {
        expect(['hour', 'day'], contains(StatsWindow.preset(kind).bucket));
      }
    });
  });

  group('CSV export', () {
    AdminStats sampleStats() => AdminStats(
          window:
              StatsWindow.custom(DateTime(2026, 3, 1), DateTime(2026, 3, 7)),
          periodMetrics: const [
            StatMetric(key: 'new_users', label: 'New sign-ups', value: 4),
          ],
          standingMetrics: const [
            StatMetric(
                key: 'current_banned',
                label: 'Banned',
                value: 2,
                isStanding: true),
          ],
          series: [
            TimeseriesPoint(
              bucket: DateTime.utc(2026, 3, 1),
              newUsers: 4,
              reportsFiled: 1,
              moderationActions: 0,
              officialAlerts: 0,
              emergencyFlares: 2,
            ),
          ],
          activeUsers: const [
            ActiveUser(
              userId: 'u1',
              username: 'victor',
              role: 'student',
              banned: false,
              suspended: false,
              reportsFiled: 1,
              reportsReceived: 2,
              warningsReceived: 0,
              alertsSent: 0,
              flaresRaised: 1,
              activityScore: 9,
            ),
          ],
        );

    test('contains every section', () {
      final csv = AdminStatsService.instance.buildCsv(sampleStats());
      expect(csv, contains('Activity in period'));
      expect(csv, contains('Current totals'));
      expect(csv, contains('Over time'));
      expect(csv, contains('Most active users'));
    });

    test('labels standing totals as not period-limited', () {
      // Printed and handed round, "2 banned" must not read as two bans
      // during the selected week.
      final csv = AdminStatsService.instance.buildCsv(sampleStats());
      expect(csv, contains('point-in-time'));
    });

    test('records the exact range and generation time', () {
      // A printed statistic with no period on it is unusable as evidence.
      final csv = AdminStatsService.instance.buildCsv(sampleStats());
      expect(csv, contains('Range start (UTC)'));
      expect(csv, contains('Range end (UTC)'));
      expect(csv, contains('Generated (UTC)'));
    });

    test('states what the data does not cover', () {
      final csv = AdminStatsService.instance.buildCsv(sampleStats());
      expect(csv.toLowerCase(), contains('stay on each device'));
    });

    test('quotes a field containing a comma', () {
      // A username or label with a comma would otherwise shift every
      // later column silently, the classic CSV corruption.
      final stats = AdminStats(
        window: StatsWindow.preset(StatsRange.last7d),
        periodMetrics: const [
          StatMetric(key: 'k', label: 'Reports, filed', value: 3),
        ],
        standingMetrics: const [],
        series: const [],
        activeUsers: const [],
      );
      final csv = AdminStatsService.instance.buildCsv(stats);
      expect(csv, contains('"Reports, filed",3'));
    });

    test('escapes an embedded quote by doubling it', () {
      final stats = AdminStats(
        window: StatsWindow.preset(StatsRange.last7d),
        periodMetrics: const [
          StatMetric(key: 'k', label: 'He said "hi"', value: 1),
        ],
        standingMetrics: const [],
        series: const [],
        activeUsers: const [],
      );
      final csv = AdminStatsService.instance.buildCsv(stats);
      expect(csv, contains('"He said ""hi""",1'));
    });

    test('leaves an ordinary field unquoted', () {
      final csv = AdminStatsService.instance.buildCsv(sampleStats());
      expect(csv, contains('New sign-ups,4'));
    });
  });

  group('series labels', () {
    test('every chart series resolves on a point', () {
      // A label with no matching case in valueFor would plot a flat zero
      // line and look like real data.
      final p = TimeseriesPoint(
        bucket: DateTime.utc(2026, 1, 1),
        newUsers: 1,
        reportsFiled: 2,
        moderationActions: 3,
        officialAlerts: 4,
        emergencyFlares: 5,
      );
      for (final key in kStatsSeriesLabels.keys) {
        expect(p.valueFor(key), greaterThan(0),
            reason: 'a series offered in the picker reads as zero');
      }
    });
  });
}
