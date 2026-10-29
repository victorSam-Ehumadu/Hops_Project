// The admin statistics view: filterable date range, charts, a most-active
// ranking, and CSV export.
//
// Charts are hand-painted with CustomPainter rather than pulled from a
// charting package. Two reasons: the app has no chart dependency and this
// is not enough chart to justify adding one (~40 lines of painter against
// a package plus its transitive tree), and a painter inherits the active
// Hops theme directly — the theme catalogue is data-driven and
// user-switchable (see theme/app_theme.dart), so a package's own palette
// would need re-theming per theme anyway.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:client/services/admin_stats_service.dart';
import 'package:client/utils/auth_error_messages.dart';

class AdminStatisticsScreen extends StatefulWidget {
  const AdminStatisticsScreen({super.key});

  @override
  State<AdminStatisticsScreen> createState() => _AdminStatisticsScreenState();
}

class _AdminStatisticsScreenState extends State<AdminStatisticsScreen> {
  StatsWindow _window = StatsWindow.preset(StatsRange.last7d);
  String _series = 'new_users';

  AdminStats? _stats;
  bool _loading = true;
  String? _error;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Your session has expired — sign in again.';
          });
        }
        return;
      }
      final stats = await AdminStatsService.instance.fetch(token, _window);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A missing function here means 0022 has not been applied, which
        // is a setup state rather than a fault — say so specifically, the
        // way admin_user_detail_screen does for 0015.
        _error = e.message.contains('does not exist')
            ? 'Server missing these statistics — run migration 0022.'
            : describeAuthException(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeAuthException(e);
      });
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      // No future dates: a range running past now would produce empty
      // trailing buckets that read as a sudden drop to zero.
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _window.from.toLocal(),
        end: _window.to.toLocal().isAfter(now) ? now : _window.to.toLocal(),
      ),
      helpText: 'Select a reporting period',
    );
    if (picked == null) return;
    setState(() => _window = StatsWindow.custom(picked.start, picked.end));
    await _load();
  }

  Future<void> _selectPreset(StatsRange kind) async {
    if (kind == StatsRange.custom) {
      await _pickCustomRange();
      return;
    }
    setState(() => _window = StatsWindow.preset(kind));
    await _load();
  }

  Future<void> _export() async {
    final stats = _stats;
    if (stats == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final csv = AdminStatsService.instance.buildCsv(stats);
      // Written to a real file and shared rather than dumped as share
      // text: a spreadsheet can open the file, and share text would be
      // truncated by most targets well before the time series ended.
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/hops-statistics-$stamp.csv');
      await file.writeAsString(csv);
      if (!mounted) return;
      // Share.shareXFiles, matching received_files_page.dart — share_plus
      // 10.x. The newer SharePlus.instance API is 11+.
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Hops statistics — ${stats.window.label}',
        text: 'Hops administrative statistics for ${stats.window.label}.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't export: $e")),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Export as CSV',
            onPressed: (_stats == null || _exporting) ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _rangeSelector(colors),
            const SizedBox(height: 6),
            Text(
              _window.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorBox(colors)
            else if (_stats != null) ...[
              _chartCard(colors, _stats!),
              const SizedBox(height: 18),
              _sectionTitle('Activity in this period', colors),
              _metricGrid(colors, _stats!.periodMetrics),
              const SizedBox(height: 18),
              _sectionTitle('Current totals', colors),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Point-in-time, not limited to the selected period.',
                  style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurface.withValues(alpha: 0.6)),
                ),
              ),
              _metricGrid(colors, _stats!.standingMetrics),
              const SizedBox(height: 18),
              _sectionTitle('Most active users', colors),
              _activeUsers(colors, _stats!.activeUsers),
              const SizedBox(height: 20),
              _dataScopeNote(colors),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rangeSelector(ColorScheme colors) {
    const presets = {
      StatsRange.last24h: '24 hours',
      StatsRange.last7d: '7 days',
      StatsRange.last30d: '30 days',
      StatsRange.custom: 'Custom',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in presets.entries)
          ChoiceChip(
            label: Text(entry.value, style: const TextStyle(fontSize: 12)),
            selected: _window.kind == entry.key,
            onSelected: _loading ? null : (_) => _selectPreset(entry.key),
            avatar: entry.key == StatsRange.custom
                ? Icon(Icons.date_range_rounded,
                    size: 15,
                    color: _window.kind == entry.key
                        ? colors.onPrimary
                        : colors.onSurface)
                : null,
          ),
      ],
    );
  }

  Widget _errorBox(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.error_outline, color: colors.error),
          const SizedBox(height: 8),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, ColorScheme colors) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.9,
            fontWeight: FontWeight.w800,
            color: colors.primary,
          ),
        ),
      );

  Widget _chartCard(ColorScheme colors, AdminStats stats) {
    final values =
        stats.series.map((p) => p.valueFor(_series)).toList(growable: false);
    final total = values.fold<int>(0, (a, b) => a + b);
    final peak = values.isEmpty ? 0 : values.reduce(math.max);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _series,
                isDense: true,
                isExpanded: true,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface),
                items: [
                  for (final e in kStatsSeriesLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) =>
                    v == null ? null : setState(() => _series = v),
              ),
            ),
            Text(
              '$total in this period · peak $peak per '
              '${stats.window.bucket}',
              style: TextStyle(
                  fontSize: 11,
                  color: colors.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 14),
            if (values.isEmpty || total == 0)
              // An explicit empty state. A flat axis with no bars is
              // ambiguous between "nothing happened" and "failed to
              // load", and the difference matters to a moderator.
              SizedBox(
                height: 150,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bar_chart_rounded,
                          size: 30,
                          color: colors.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 8),
                      Text(
                        'Nothing recorded in this period.',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                colors.onSurface.withValues(alpha: 0.55)),
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                height: 150,
                child: CustomPaint(
                  painter: BarChartPainter(
                    values: values,
                    barColor: colors.primary,
                    axisColor: colors.onSurface.withValues(alpha: 0.18),
                    textColor: colors.onSurface.withValues(alpha: 0.65),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            const SizedBox(height: 6),
            if (stats.series.isNotEmpty)
              Padding(
                // Matches BarChartPainter._axisLabelWidth so the first
                // bucket caption sits under the first bar, not under the
                // y-axis numbers.
                padding: const EdgeInsets.only(left: 26),
                child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_axisLabel(stats.series.first.bucket, stats),
                      style: TextStyle(
                          fontSize: 10,
                          color:
                              colors.onSurface.withValues(alpha: 0.5))),
                  Text(_axisLabel(stats.series.last.bucket, stats),
                      style: TextStyle(
                          fontSize: 10,
                          color:
                              colors.onSurface.withValues(alpha: 0.5))),
                ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _axisLabel(DateTime d, AdminStats stats) {
    String two(int v) => v.toString().padLeft(2, '0');
    return stats.window.bucket == 'hour'
        ? '${two(d.hour)}:00'
        : '${two(d.day)}/${two(d.month)}';
  }

  Widget _metricGrid(ColorScheme colors, List<StatMetric> metrics) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.05,
      children: [
        for (final m in metrics)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${m.value}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  m.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.25,
                      color: colors.onSurface.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _activeUsers(ColorScheme colors, List<ActiveUser> users) {
    if (users.isEmpty) {
      return Text(
        'No recorded activity in this period.',
        style: TextStyle(
            fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < users.length; i++)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 14,
                backgroundColor: colors.primary.withValues(alpha: 0.15),
                child: Text('${i + 1}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: colors.primary)),
              ),
              title: Row(
                children: [
                  Flexible(
                    child: Text(users[i].username,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (users[i].role == 'admin') _tag('ADMIN', colors.primary),
                  if (users[i].banned) _tag('BANNED', colors.error),
                  if (users[i].suspended) _tag('SUSPENDED', Colors.orange),
                ],
              ),
              // The components, never just the score — a moderator acting
              // on this needs to see WHY someone is ranked here. An opaque
              // number would get acted on without that.
              subtitle: Text(
                'filed ${users[i].reportsFiled} · '
                'reported ${users[i].reportsReceived} · '
                'warned ${users[i].warningsReceived} · '
                'flares ${users[i].flaresRaised}',
                style: TextStyle(
                    fontSize: 10.5,
                    color: colors.onSurface.withValues(alpha: 0.6)),
              ),
              trailing: Text(
                '${users[i].activityScore}',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: colors.primary),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tag(String text, Color color) => Padding(
        padding: const EdgeInsets.only(left: 5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 8.5, fontWeight: FontWeight.w800, color: color)),
        ),
      );

  /// States what these numbers cover. Not boilerplate: a dashboard that
  /// silently omits all feature usage invites the conclusion that nobody
  /// uses the app, when in fact that data deliberately never leaves the
  /// device. Also the honest answer to "why is there no message count".
  Widget _dataScopeNote(ColorScheme colors) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline,
                size: 15, color: colors.onSurface.withValues(alpha: 0.5)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'These figures cover accounts, moderation and Emergency '
                'Flares — the only things Hops keeps on the server. '
                'Messages, chats, vibe reports, tasks and games stay on '
                'each device by design and are never collected, so they '
                'cannot appear here.',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: colors.onSurface.withValues(alpha: 0.6)),
              ),
            ),
          ],
        ),
      );
}

/// A minimal bar chart.
///
/// Public, and named without an underscore, so its edge cases are
/// reachable from a test: an empty series, an all-zero series, a single
/// bucket, 30 buckets on a narrow phone, and a canvas too small to hold
/// the y-axis gutter. Each of those is a division or a negative width
/// waiting to happen, and none is reachable by pumping the screen (which
/// needs a live Supabase).
///
/// Bars are laid out to fill the width, so the same painter reads correctly
/// for 24 hourly buckets and 30 daily ones without configuration. Below
/// roughly 2px per bar the gaps are dropped rather than letting bars
/// vanish entirely.
class BarChartPainter extends CustomPainter {
  final List<int> values;
  final Color barColor;
  final Color axisColor;
  final Color textColor;

  const BarChartPainter({
    required this.values,
    required this.barColor,
    required this.axisColor,
    required this.textColor,
  });

  /// Width reserved on the left for the y-axis numbers. Fixed rather than
  /// measured so the plot area does not shift width as the peak value
  /// gains a digit, which made the bars visibly jump when switching series.
  static const double _axisLabelWidth = 26;

  TextPainter _label(String text, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
            fontSize: size, color: color, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    return tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    // Max of at least 1 so an all-zero series does not divide by zero and
    // does not draw full-height bars for nothing.
    final maxValue = math.max(1, values.reduce(math.max));

    // Headroom at the top for the value printed above the tallest bar,
    // otherwise the peak's own label is clipped off the canvas.
    const topPad = 13.0;
    const plotLeft = _axisLabelWidth;
    final plotWidth = size.width - plotLeft;
    final plotHeight = size.height - topPad;
    if (plotWidth <= 0) return;

    final axis = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(plotLeft, size.height),
        Offset(size.width, size.height), axis);

    // Gridlines at the peak and at half, each with its value on the left.
    // Two lines rather than a full grid: this is a 150px-tall chart on a
    // phone, and more would be noise rather than information.
    final faint = Paint()
      ..color = axisColor.withValues(alpha: 0.4)
      ..strokeWidth = 0.5;

    void gridline(double fraction, int value) {
      final y = size.height - (plotHeight * fraction);
      canvas.drawLine(Offset(plotLeft, y), Offset(size.width, y), faint);
      final tp = _label('$value', 9, textColor);
      // Right-aligned against the plot edge so 1 and 100 line up.
      tp.paint(canvas,
          Offset(plotLeft - tp.width - 4, y - tp.height / 2));
    }

    gridline(1.0, maxValue);
    // Only when it is a distinct whole number — at a peak of 1 a "0" label
    // halfway up is worse than no label.
    if (maxValue >= 2) gridline(0.5, maxValue ~/ 2);
    final zero = _label('0', 9, textColor);
    zero.paint(canvas,
        Offset(plotLeft - zero.width - 4, size.height - zero.height / 2 - 1));

    final slot = plotWidth / values.length;
    final gap = slot > 4 ? math.min(3.0, slot * 0.25) : 0.0;
    final barWidth = math.max(1.0, slot - gap);

    // Per-bar values only when they will actually be readable. Below about
    // 14px of slot the numbers overlap each other, which is worse than the
    // y-axis alone — the gridlines still give the magnitude.
    final labelBars = slot >= 14;

    final bar = Paint()..color = barColor;
    for (var i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final h = (values[i] / maxValue) * plotHeight;
      final left = plotLeft + i * slot + gap / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(left, size.height - h, barWidth, h),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        bar,
      );
      if (labelBars) {
        final tp = _label('${values[i]}', 8.5, textColor);
        if (tp.width <= slot) {
          tp.paint(
            canvas,
            Offset(left + (barWidth - tp.width) / 2,
                size.height - h - tp.height - 1),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(BarChartPainter old) =>
      !listEquals(old.values, values) ||
      old.barColor != barColor ||
      old.axisColor != axisColor ||
      old.textColor != textColor;
}
