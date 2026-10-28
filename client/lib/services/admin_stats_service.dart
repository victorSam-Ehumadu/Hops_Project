// Admin statistics: date-ranged totals, time series for charts, and a
// most-active-users ranking. Backed by the three RPCs in
// 0022_admin_statistics.sql.
//
// WHAT THESE NUMBERS CAN AND CANNOT SAY
//
// Hops has no server-side data plane. Chat messages, vibe reports, tasks,
// study tags and games live on the device and never reach Postgres (see
// CLAUDE.md), so the server cannot report on them at all and nothing here
// pretends otherwise. What it holds is identity and moderation, plus
// Emergency Flares — which ARE logged server-side.
//
// This matters for presenting the dashboard honestly: "most active user"
// means most server-visible activity, and the UI labels it that way
// rather than implying it ranks people by app usage.
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A selectable window. Custom carries its own explicit bounds.
enum StatsRange { last24h, last7d, last30d, custom }

@immutable
class StatsWindow {
  final StatsRange kind;
  final DateTime from;
  final DateTime to;

  const StatsWindow({
    required this.kind,
    required this.from,
    required this.to,
  });

  /// Builds a window ending now. `to` is deliberately "now" rather than
  /// the end of today: a range running into the future would make the
  /// final chart bucket permanently partial and look like a cliff.
  factory StatsWindow.preset(StatsRange kind) {
    final now = DateTime.now().toUtc();
    switch (kind) {
      case StatsRange.last24h:
        return StatsWindow(
            kind: kind, from: now.subtract(const Duration(hours: 24)), to: now);
      case StatsRange.last7d:
        return StatsWindow(
            kind: kind, from: now.subtract(const Duration(days: 7)), to: now);
      case StatsRange.last30d:
        return StatsWindow(
            kind: kind, from: now.subtract(const Duration(days: 30)), to: now);
      case StatsRange.custom:
        return StatsWindow(
            kind: kind, from: now.subtract(const Duration(days: 7)), to: now);
    }
  }

  /// A custom window from two picked dates.
  ///
  /// The end date is pushed to the end of its day, because someone
  /// choosing "1st to 7th" means the whole of the 7th. Treating the picked
  /// date as midnight would silently drop a day — a classic off-by-one in
  /// exactly the place nobody checks.
  factory StatsWindow.custom(DateTime fromDate, DateTime toDate) {
    final from = DateTime(fromDate.year, fromDate.month, fromDate.day).toUtc();
    final to = DateTime(toDate.year, toDate.month, toDate.day, 23, 59, 59, 999)
        .toUtc();
    return StatsWindow(kind: StatsRange.custom, from: from, to: to);
  }

  /// Hourly buckets for short windows, daily for long ones.
  ///
  /// Hourly over 30 days would be 720 points — unreadable on a phone and
  /// slow to fetch. Daily over 24 hours would be a single bar, which is
  /// not a chart.
  String get bucket =>
      to.difference(from).inHours <= 48 ? 'hour' : 'day';

  String get label {
    switch (kind) {
      case StatsRange.last24h:
        return 'Last 24 hours';
      case StatsRange.last7d:
        return 'Last 7 days';
      case StatsRange.last30d:
        return 'Last 30 days';
      case StatsRange.custom:
        final f = from.toLocal();
        final t = to.toLocal();
        return '${_d(f)} – ${_d(t)}';
    }
  }

  static String _d(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// One metric, as shown on a card and written to the export.
@immutable
class StatMetric {
  final String key;
  final String label;
  final int value;

  /// True for point-in-time totals ("banned right now") as opposed to
  /// counts within the window. Mixing the two unlabelled would be
  /// misleading — "12 banned" reads as 12 bans this week when it is
  /// actually 12 banned accounts in total.
  final bool isStanding;

  const StatMetric({
    required this.key,
    required this.label,
    required this.value,
    this.isStanding = false,
  });
}

@immutable
class TimeseriesPoint {
  final DateTime bucket;
  final int newUsers;
  final int reportsFiled;
  final int moderationActions;
  final int officialAlerts;
  final int emergencyFlares;

  const TimeseriesPoint({
    required this.bucket,
    required this.newUsers,
    required this.reportsFiled,
    required this.moderationActions,
    required this.officialAlerts,
    required this.emergencyFlares,
  });

  int valueFor(String series) {
    switch (series) {
      case 'new_users':
        return newUsers;
      case 'reports_filed':
        return reportsFiled;
      case 'moderation_actions':
        return moderationActions;
      case 'official_alerts':
        return officialAlerts;
      case 'emergency_flares':
        return emergencyFlares;
      default:
        return 0;
    }
  }
}

@immutable
class ActiveUser {
  final String userId;
  final String username;
  final String role;
  final bool banned;
  final bool suspended;
  final int reportsFiled;
  final int reportsReceived;
  final int warningsReceived;
  final int alertsSent;
  final int flaresRaised;
  final int activityScore;

  const ActiveUser({
    required this.userId,
    required this.username,
    required this.role,
    required this.banned,
    required this.suspended,
    required this.reportsFiled,
    required this.reportsReceived,
    required this.warningsReceived,
    required this.alertsSent,
    required this.flaresRaised,
    required this.activityScore,
  });
}

@immutable
class AdminStats {
  final StatsWindow window;
  final List<StatMetric> periodMetrics;
  final List<StatMetric> standingMetrics;
  final List<TimeseriesPoint> series;
  final List<ActiveUser> activeUsers;

  const AdminStats({
    required this.window,
    required this.periodMetrics,
    required this.standingMetrics,
    required this.series,
    required this.activeUsers,
  });
}

/// The chart series a user can switch between.
const Map<String, String> kStatsSeriesLabels = {
  'new_users': 'New sign-ups',
  'reports_filed': 'Reports filed',
  'moderation_actions': 'Moderation actions',
  'emergency_flares': 'Emergency Flares',
  'official_alerts': 'Official Alerts',
};

class AdminStatsService {
  AdminStatsService._();
  static final AdminStatsService instance = AdminStatsService._();

  /// Fetches everything for [window] in one go.
  ///
  /// The three RPCs are issued concurrently — they are independent reads,
  /// and doing them in sequence made switching a filter feel sluggish on
  /// a slow connection for no reason.
  Future<AdminStats> fetch(String token, StatsWindow window) async {
    final client = Supabase.instance.client;
    final fromIso = window.from.toUtc().toIso8601String();
    final toIso = window.to.toUtc().toIso8601String();

    // Explicitly typed: the three calls return different shapes (a Map
    // and two Lists), so inference lands on List<Object> and refuses.
    final results = await Future.wait<dynamic>([
      client.rpc('get_admin_stats_range', params: {
        'p_hops_token': token,
        'p_from': fromIso,
        'p_to': toIso,
      }).single(),
      client.rpc('get_admin_stats_timeseries', params: {
        'p_hops_token': token,
        'p_from': fromIso,
        'p_to': toIso,
        'p_bucket': window.bucket,
      }),
      client.rpc('get_admin_most_active_users', params: {
        'p_hops_token': token,
        'p_from': fromIso,
        'p_to': toIso,
        'p_limit': 10,
      }),
    ]);

    final totals = results[0] as Map<String, dynamic>;
    final seriesRows = (results[1] as List).cast<Map<String, dynamic>>();
    final activeRows = (results[2] as List).cast<Map<String, dynamic>>();

    int n(String k) => (totals[k] as num?)?.toInt() ?? 0;

    return AdminStats(
      window: window,
      periodMetrics: [
        StatMetric(key: 'new_users', label: 'New sign-ups', value: n('new_users')),
        StatMetric(
            key: 'reports_filed',
            label: 'Reports filed',
            value: n('reports_filed')),
        StatMetric(
            key: 'reports_resolved',
            label: 'Reports resolved',
            value: n('reports_resolved')),
        StatMetric(
            key: 'emergency_flares',
            label: 'Emergency Flares',
            value: n('emergency_flares')),
        StatMetric(
            key: 'warnings_issued',
            label: 'Warnings issued',
            value: n('warnings_issued')),
        StatMetric(
            key: 'bans_issued', label: 'Bans issued', value: n('bans_issued')),
        StatMetric(
            key: 'suspensions_issued',
            label: 'Suspensions',
            value: n('suspensions_issued')),
        StatMetric(
            key: 'official_alerts',
            label: 'Official Alerts',
            value: n('official_alerts')),
        StatMetric(
            key: 'notifications_sent',
            label: 'Notifications sent',
            value: n('notifications_sent')),
      ],
      standingMetrics: [
        StatMetric(
            key: 'current_total_users',
            label: 'Total accounts',
            value: n('current_total_users'),
            isStanding: true),
        StatMetric(
            key: 'current_open_reports',
            label: 'Open reports',
            value: n('current_open_reports'),
            isStanding: true),
        StatMetric(
            key: 'current_banned',
            label: 'Banned',
            value: n('current_banned'),
            isStanding: true),
        StatMetric(
            key: 'current_suspended',
            label: 'Suspended',
            value: n('current_suspended'),
            isStanding: true),
        StatMetric(
            key: 'current_email_verified',
            label: 'Email verified',
            value: n('current_email_verified'),
            isStanding: true),
        StatMetric(
            key: 'current_admins',
            label: 'Admins',
            value: n('current_admins'),
            isStanding: true),
      ],
      series: seriesRows.map((r) {
        int s(String k) => (r[k] as num?)?.toInt() ?? 0;
        return TimeseriesPoint(
          // Parsed as UTC then shown local — the server buckets in UTC.
          bucket: DateTime.parse(r['bucket'] as String).toLocal(),
          newUsers: s('new_users'),
          reportsFiled: s('reports_filed'),
          moderationActions: s('moderation_actions'),
          officialAlerts: s('official_alerts'),
          emergencyFlares: s('emergency_flares'),
        );
      }).toList(),
      activeUsers: activeRows.map((r) {
        int s(String k) => (r[k] as num?)?.toInt() ?? 0;
        return ActiveUser(
          userId: r['user_id'] as String? ?? '',
          username: r['username'] as String? ?? '(unknown)',
          role: r['role'] as String? ?? 'student',
          banned: r['banned'] as bool? ?? false,
          suspended: r['suspended'] as bool? ?? false,
          reportsFiled: s('reports_filed'),
          reportsReceived: s('reports_received'),
          warningsReceived: s('warnings_received'),
          alertsSent: s('alerts_sent'),
          flaresRaised: s('flares_raised'),
          activityScore: s('activity_score'),
        );
      }).toList(),
    );
  }

  /// Renders the whole report as CSV, for printing or opening in a
  /// spreadsheet.
  ///
  /// CSV rather than PDF deliberately: it needs no new dependency, opens
  /// in Excel and Sheets, prints from either, and — unlike a rendered
  /// PDF — the numbers stay usable if someone wants to chart them
  /// differently or paste them into the report.
  ///
  /// Sections are separated by blank lines with their own headers, which
  /// every spreadsheet handles, rather than being forced into one table
  /// whose columns would mean different things per row.
  String buildCsv(AdminStats stats) {
    final b = StringBuffer();

    b.writeln('Hops administrative statistics');
    b.writeln('Period,${_csv(stats.window.label)}');
    b.writeln('Range start (UTC),${stats.window.from.toIso8601String()}');
    b.writeln('Range end (UTC),${stats.window.to.toIso8601String()}');
    b.writeln('Generated (UTC),${DateTime.now().toUtc().toIso8601String()}');
    b.writeln();

    b.writeln('Activity in period');
    b.writeln('Metric,Value');
    for (final m in stats.periodMetrics) {
      b.writeln('${_csv(m.label)},${m.value}');
    }
    b.writeln();

    // Labelled as current rather than listed with the above, so a printed
    // copy cannot be read as "5 banned during this week".
    b.writeln('Current totals (point-in-time, not limited to the period)');
    b.writeln('Metric,Value');
    for (final m in stats.standingMetrics) {
      b.writeln('${_csv(m.label)},${m.value}');
    }
    b.writeln();

    b.writeln('Over time (bucket: ${stats.window.bucket})');
    b.writeln('Bucket start,New sign-ups,Reports filed,'
        'Moderation actions,Emergency Flares,Official Alerts');
    for (final p in stats.series) {
      b.writeln('${p.bucket.toIso8601String()},${p.newUsers},'
          '${p.reportsFiled},${p.moderationActions},'
          '${p.emergencyFlares},${p.officialAlerts}');
    }
    b.writeln();

    b.writeln('Most active users (server-visible activity only)');
    b.writeln('Username,Role,Standing,Reports filed,Reports received,'
        'Warnings received,Flares raised,Official Alerts,Activity score');
    for (final u in stats.activeUsers) {
      final standing =
          u.banned ? 'banned' : (u.suspended ? 'suspended' : 'ok');
      b.writeln('${_csv(u.username)},${u.role},$standing,'
          '${u.reportsFiled},${u.reportsReceived},${u.warningsReceived},'
          '${u.flaresRaised},${u.alertsSent},${u.activityScore}');
    }
    b.writeln();
    b.writeln('Note');
    b.writeln(_csv('Hops stores no message, chat or feature data on the '
        'server — those stay on each device. These figures therefore cover '
        'accounts, moderation and Emergency Flares only.'));

    return b.toString();
  }

  /// Quotes a CSV field. Only quotes when needed, and doubles embedded
  /// quotes per RFC 4180 — a report reason or username can contain a
  /// comma, and an unquoted one silently shifts every later column.
  static String _csv(String value) {
    if (!value.contains(',') &&
        !value.contains('"') &&
        !value.contains('\n')) {
      return value;
    }
    return '"${value.replaceAll('"', '""')}"';
  }
}
