// lib/views/admin/admin_action_log_tab.dart
//
// Read-only audit trail — every ban/unban/delete/promote/demote/report-
// resolution/official-alert/emergency-flare/warning any admin or student
// has triggered, via list_admin_actions_log (0008_admin_moderation.sql,
// extended in 0010_notifications_and_logging.sql to also carry personal
// Emergency Flares and warnings).
//
// Filtered by time window and by kind of action, both client-side. The RPC
// returns at most 300 rows newest-first, so filtering here costs nothing
// extra and avoids a migration — but it does mean a window can be clipped
// by that cap rather than by the window itself, which is why
// _mayBeClipped() says so out loud instead of quietly showing less.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:client/utils/admin_error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/services/admin_stats_service.dart';
import 'package:client/utils/day_grouping.dart';

class AdminActionLogTab extends StatefulWidget {
  const AdminActionLogTab({super.key});

  @override
  State<AdminActionLogTab> createState() => _AdminActionLogTabState();
}

class _AdminActionLogTabState extends State<AdminActionLogTab> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;
  Timer? _autoRefreshTimer;

  // Same window model the Statistics screen uses, rather than a second
  // one that drifts from it — including its rule that a window ends
  // "now" and never in the future.
  StatsWindow _window = StatsWindow.preset(StatsRange.last7d);

  // Empty means "every kind", which is also the default. Holding the
  // selection as a set of GROUP keys rather than raw action strings keeps
  // the UI from sprouting a chip per database value — several of them
  // (promote_admin/demote_admin/delete_user) are one idea to a reader.
  final Set<String> _kinds = {};

  // The most rows list_admin_actions_log will return (it clamps to 300).
  static const int _rowLimit = 300;

  @override
  void initState() {
    super.initState();
    _load();
    // Background refresh — this list is meant to double as a near-live
    // feed of flares/alerts as they happen, not just a manually-checked
    // history. The refresh button (still there) stays useful for "I want
    // this second's state right now" without waiting out the interval.
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  // [silent] skips the full-page spinner — used by the 10s background
  // timer so it doesn't flash the whole list away every refresh; the
  // manual refresh button and the initial load still want the spinner.
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Not signed in.";
        });
      }
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .rpc('list_admin_actions_log',
              params: {'p_hops_token': token, 'p_limit': _rowLimit});
      if (mounted) {
        setState(() {
          _entries = (rows as List).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (e) {
      // A silent background refresh that fails (offline, momentary hiccup)
      // shouldn't blow away an already-successfully-loaded list with an
      // error screen — just leave the last good state up and try again in
      // 10s.
      if (mounted && !silent) {
        setState(() {
          _loading = false;
          _error = describeAdminError(e, fallbackSubject: "the action log");
        });
      }
    }
  }

  // ── Filtering ────────────────────────────────────────────────────────
  //
  // Grouped into the kinds an admin actually thinks in, not one chip per
  // database value: promote/demote/delete are three action strings but one
  // idea ("account changes"), and resolve_report is two ideas (resolved vs
  // dismissed) sharing one string.
  static const Map<String, String> _kindLabels = {
    'ban': 'Bans',
    'suspend': 'Suspensions',
    'unban': 'Unbans',
    'unsuspend': 'Unsuspensions',
    'warn': 'Warnings',
    'report_resolved': 'Reports resolved',
    'report_dismissed': 'Reports dismissed',
    'flare': 'Emergency flares',
    'alert': 'Official alerts',
    'account': 'Account changes',
  };

  /// Which filter group a row belongs to, or null if it matches none.
  ///
  /// The resolved/dismissed split reads the reason, because the log row
  /// records the admin's action label and not the report's status — a
  /// dismissal is written with the literal label "Dismissed" by
  /// admin_moderation_tab.dart. If that label ever changes, this follows
  /// it or the two groups silently merge.
  static String? _kindOf(Map<String, dynamic> e) {
    final action = e['action'] as String? ?? '';
    switch (action) {
      case 'ban':
        return 'ban';
      case 'suspend':
        return 'suspend';
      case 'unban':
        return 'unban';
      case 'unsuspend':
        return 'unsuspend';
      case 'warn_user':
        return 'warn';
      case 'emergency_flare':
        return 'flare';
      case 'official_alert':
        return 'alert';
      case 'delete_user':
      case 'promote_admin':
      case 'demote_admin':
        return 'account';
      case 'resolve_report':
        final reason = (e['reason'] as String? ?? '').trim().toLowerCase();
        return reason == 'dismissed' ? 'report_dismissed' : 'report_resolved';
      default:
        return null;
    }
  }

  DateTime? _timeOf(Map<String, dynamic> e) =>
      DateTime.tryParse(e['created_at'] as String? ?? '')?.toLocal();

  List<Map<String, dynamic>> get _visible {
    final from = _window.from.toLocal();
    final to = _window.to.toLocal();
    return _entries.where((e) {
      final when = _timeOf(e);
      if (when == null) return false;
      if (when.isBefore(from) || when.isAfter(to)) return false;
      if (_kinds.isEmpty) return true;
      final kind = _kindOf(e);
      return kind != null && _kinds.contains(kind);
    }).toList();
  }

  /// True when the row cap, rather than the chosen window, may be what is
  /// limiting the list. Worth saying: a 30-day window that silently shows
  /// only the newest 300 entries looks like a quiet month.
  bool get _mayBeClipped {
    if (_entries.length < _rowLimit) return false;
    final oldest = _timeOf(_entries.last);
    return oldest != null && oldest.isAfter(_window.from.toLocal());
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: DateTimeRange(
          start: now.subtract(const Duration(days: 7)), end: now),
    );
    if (picked == null) return;
    setState(() => _window = StatsWindow.custom(picked.start, picked.end));
  }

  Future<void> _selectPreset(StatsRange kind) async {
    if (kind == StatsRange.custom) {
      await _pickCustomRange();
      return;
    }
    setState(() => _window = StatsWindow.preset(kind));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = _loading || _error != null ? const [] : _visible;
    return Scaffold(
      appBar: AppBar(
        title: Text("Action Log",
            style: TextStyle(
                color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
              tooltip: "Refresh")
        ],
      ),
      body: Column(
        children: [
          _filterBar(colors, rows.length),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : rows.isEmpty
                        ? _emptyState(colors)
                        : _logList(
                            rows.cast<Map<String, dynamic>>(), colors),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(ColorScheme colors) {
    final filtered = _kinds.isNotEmpty || _entries.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          filtered
              ? "Nothing in this window matches those filters."
              : "No admin actions yet.",
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
        ),
      ),
    );
  }

  static const Map<StatsRange, String> _rangeLabels = {
    StatsRange.last24h: 'Last 24 hours',
    StatsRange.last7d: 'Last 7 days',
    StatsRange.last30d: 'Last 30 days',
    StatsRange.custom: 'Custom range',
  };

  String get _rangeLabel {
    if (_window.kind != StatsRange.custom) {
      return _rangeLabels[_window.kind]!;
    }
    final f = _window.from.toLocal();
    final t = _window.to.toLocal();
    String d(DateTime x) =>
        '${x.day}/${x.month.toString().padLeft(2, '0')}';
    return '${d(f)} – ${d(t)}';
  }

  String get _kindsLabel {
    if (_kinds.isEmpty) return 'All actions';
    if (_kinds.length == 1) return _kindLabels[_kinds.first]!;
    return '${_kinds.length} action types';
  }

  /// Two buttons rather than fourteen chips. The labels carry the current
  /// selection, so nothing is hidden by collapsing them — a glance still
  /// says "Last 7 days, All actions" without the controls taking the top
  /// third of a phone screen.
  Widget _filterBar(ColorScheme colors, int shown) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _filterButton(
                  colors,
                  icon: Icons.schedule,
                  label: _rangeLabel,
                  onTap: _loading ? null : _pickRange,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _filterButton(
                  colors,
                  icon: Icons.filter_list,
                  label: _kindsLabel,
                  active: _kinds.isNotEmpty,
                  onTap: _loading ? null : _pickKinds,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                shown == 1 ? "1 entry" : "$shown entries",
                style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurface.withValues(alpha: 0.5)),
              ),
              if (_kinds.isNotEmpty) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => setState(_kinds.clear),
                  child: Text("Clear filters",
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: colors.primary)),
                ),
              ],
            ],
          ),
          if (_mayBeClipped) ...[
            const SizedBox(height: 4),
            Text(
              "Showing the most recent $_rowLimit actions — older ones in "
              "this range aren't loaded.",
              style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: colors.onSurface.withValues(alpha: 0.5)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterButton(
    ColorScheme colors, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    final accent = active ? colors.primary : colors.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: active
                ? colors.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            border: Border.all(
                color: accent.withValues(alpha: active ? 0.45 : 0.25)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: accent.withValues(alpha: 0.8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.bold : FontWeight.w500,
                      color: accent),
                ),
              ),
              Icon(Icons.expand_more,
                  size: 18, color: accent.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetHandle(BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(ctx)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(100),
            ),
          ),
          const SizedBox(height: 14),
        ],
      );

  Future<void> _pickRange() async {
    final picked = await showModalBottomSheet<StatsRange>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetHandle(ctx),
            const Text("Time range",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 6),
            for (final entry in _rangeLabels.entries)
              ListTile(
                leading: Icon(entry.key == StatsRange.custom
                    ? Icons.date_range_rounded
                    : Icons.schedule),
                title: Text(entry.value, style: const TextStyle(fontSize: 14)),
                trailing: _window.kind == entry.key
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _selectPreset(picked);
  }

  Future<void> _pickKinds() async {
    // A local copy so backing out of the sheet leaves the list alone —
    // ticking four boxes and then dismissing should not have applied them
    // one at a time on the way.
    final working = Set<String>.from(_kinds);
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(ctx),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text("Filter by action",
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                    TextButton(
                      onPressed: working.isEmpty
                          ? null
                          : () => setSheetState(working.clear),
                      child: const Text("Clear"),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in _kindLabels.entries)
                      CheckboxListTile(
                        dense: true,
                        value: working.contains(entry.key),
                        title: Text(entry.value,
                            style: const TextStyle(fontSize: 14)),
                        onChanged: (on) => setSheetState(() {
                          if (on == true) {
                            working.add(entry.key);
                          } else {
                            working.remove(entry.key);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, working),
                    child: Text(working.isEmpty
                        ? "Show all actions"
                        : "Apply ${working.length} filter"
                            "${working.length == 1 ? '' : 's'}"),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    setState(() {
      _kinds
        ..clear()
        ..addAll(result);
    });
  }

  /// The list, with a separator wherever the calendar day changes.
  ///
  /// Built as a flat item list rather than nested lists so the whole thing
  /// stays lazily built — a day with 200 entries shouldn't cost anything
  /// until it is scrolled to.
  Widget _logList(List<Map<String, dynamic>> rows, ColorScheme colors) {
    final items = <Widget>[];
    DateTime? previous;
    for (final e in rows) {
      final when = _timeOf(e);
      if (when != null && (previous == null || !isSameDay(previous, when))) {
        items.add(DaySeparator.forDate(when));
        previous = when;
      }
      items.add(_logCard(e, colors));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i],
    );
  }

  Widget _logCard(Map<String, dynamic> e, ColorScheme colors) {
    final action = e['action'] as String? ?? '';
    final accent = _colorFor(action);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _showDetail(e),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              // Same shape as the Dashboard's stat cards: a tint of the
              // action's own colour inside a matching border, so the kind
              // of action is readable before the text is.
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconFor(action), color: accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_describe(e),
                          style: const TextStyle(
                              fontSize: 13, height: 1.35)),
                      const SizedBox(height: 4),
                      Text(
                        _formatTimestamp(e['created_at'] as String?),
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                colors.onSurface.withValues(alpha: 0.55)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: colors.onSurface.withValues(alpha: 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _describe(Map<String, dynamic> e) {
    final actor = e['actor_username'] as String? ?? 'Unknown';
    final action = e['action'] as String? ?? '';
    final target = e['target_username'] as String?;
    final reporter = e['reporter_username'] as String?;
    final reason = e['reason'] as String?;
    // resolve_report/warn_user rows now carry reporter_username (see
    // 0016_moderation_email_and_log_detail.sql) — surfaced inline here
    // rather than only in the detail dialog, since "who reported this"
    // used to mean opening a row to find out, or not being answerable at
    // all for rows logged before that migration.
    final reportedBy = reporter != null ? " (reported by $reporter)" : "";
    final base = switch (action) {
      'ban' => "$actor banned $target",
      'unban' => "$actor unbanned $target",
      // Logged by the server since 0015/0020 but never described here, so
      // a suspension read as the catch-all "performed suspend".
      'suspend' => "$actor suspended $target",
      'unsuspend' => "$actor lifted $target's suspension",
      'delete_user' => "$actor deleted $target's account",
      'promote_admin' => "$actor promoted $target to admin",
      'demote_admin' => "$actor demoted $target",
      'resolve_report' => target != null
          ? "$actor resolved a report on $target$reportedBy"
          : "$actor resolved a report$reportedBy",
      'official_alert' => "$actor broadcast an Official Alert",
      'emergency_flare' => "$actor triggered an Emergency Flare",
      'warn_user' => "$actor warned $target$reportedBy",
      _ => "$actor performed $action",
    };
    return reason != null && reason.isNotEmpty ? "$base — $reason" : base;
  }

  IconData _iconFor(String action) => switch (action) {
        'ban' => Icons.block,
        'unban' => Icons.check_circle_outline,
        'suspend' => Icons.pause_circle_outline,
        'unsuspend' => Icons.play_circle_outline,
        'delete_user' => Icons.person_remove,
        'promote_admin' => Icons.arrow_upward,
        'demote_admin' => Icons.arrow_downward,
        'resolve_report' => Icons.flag_outlined,
        'official_alert' => Icons.campaign,
        'emergency_flare' => Icons.warning_amber_rounded,
        'warn_user' => Icons.report_gmailerrorred,
        _ => Icons.history,
      };

  Color _colorFor(String action) => switch (action) {
        'ban' || 'delete_user' => Colors.redAccent,
        'suspend' => Colors.deepOrange,
        'unsuspend' => Colors.teal,
        'official_alert' => Colors.red.shade900,
        'emergency_flare' => Colors.orange.shade800,
        'warn_user' => Colors.amber.shade800,
        'unban' => Colors.green,
        _ => Colors.grey,
      };

  String _formatTimestamp(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "Just now";
    if (diff.inHours < 1) return "${diff.inMinutes}m ago";
    if (diff.inDays < 1) return "${diff.inHours}h ago";
    if (diff.inDays < 7) return "${diff.inDays}d ago";
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
  }

  // Exact timestamp for the detail dialog — the list itself only ever
  // shows the relative "3m ago"/"2d ago" form above, which is deliberately
  // imprecise for a scannable list but not good enough once someone's
  // actually trying to pin down when something happened.
  String _formatExactTimestamp(String? iso) {
    if (iso == null) return 'Unknown';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'Unknown';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m:$s";
  }

  void _showDetail(Map<String, dynamic> e) {
    final action = e['action'] as String? ?? '';
    final actor = e['actor_username'] as String? ?? 'Unknown';
    final target = e['target_username'] as String?;
    final reporter = e['reporter_username'] as String?;
    final reason = e['reason'] as String?;
    final snapshot = e['content_snapshot'] as String?;
    final place = e['content_place'] as String?;
    final category = e['content_category'] as String?;
    final contentSentAt = e['content_created_at'] as String?;
    final colors = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(_iconFor(action), color: _colorFor(action), size: 32),
        title: Text(_actionLabel(action)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow("By", actor, colors),
            if (target != null) _detailRow("Target", target, colors),
            // Null on rows logged before 0016_moderation_email_and_log_detail.sql
            // (reporter_username didn't exist to record) — nothing shown
            // for those rather than a misleading "Reported by: —".
            if (reporter != null) _detailRow("Reported by", reporter, colors),
            _detailRow("Action taken", _formatExactTimestamp(e['created_at'] as String?), colors),
            // The reported content itself, for actions that came from a
            // report (see 0012_action_log_report_detail.sql). Copied onto
            // the log row at write time, so it survives the report — and
            // the account — being deleted afterwards.
            if (snapshot != null && snapshot.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text("Reported content",
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: colors.onSurface.withValues(alpha: 0.5))),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('"$snapshot"',
                    style: TextStyle(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: colors.onSurface.withValues(alpha: 0.85))),
              ),
              const SizedBox(height: 8),
              if (place != null) _detailRow("Sent in", place, colors),
              if (category != null)
                _detailRow("Violation", _categoryLabel(category), colors),
              if (contentSentAt != null)
                _detailRow("Sent", _formatExactTimestamp(contentSentAt), colors),
            ],
            if (reason != null && reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text("Reason / note", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: colors.onSurface.withValues(alpha: 0.5))),
              const SizedBox(height: 2),
              Text(reason, style: const TextStyle(fontSize: 13)),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, ColorScheme colors) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: RichText(
          text: TextSpan(
            style: TextStyle(fontSize: 13, color: colors.onSurface),
            children: [
              TextSpan(text: "$label: ", style: const TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: value),
            ],
          ),
        ),
      );

  // Same labels the Reports tab uses for content_reports.category, so the
  // two screens don't describe the same violation differently.
  String _categoryLabel(String category) => switch (category) {
        'spam' => 'Spam',
        'harassment' => 'Harassment',
        'inappropriate' => 'Inappropriate content',
        'other' => 'Other',
        _ => category,
      };

  String _actionLabel(String action) => switch (action) {
        'ban' => "Ban",
        'unban' => "Unban",
        'suspend' => "Suspension",
        'unsuspend' => "Suspension lifted",
        'delete_user' => "Account deleted",
        'promote_admin' => "Promoted to admin",
        'demote_admin' => "Demoted",
        'resolve_report' => "Report resolved",
        'official_alert' => "Official Alert",
        'emergency_flare' => "Emergency Flare",
        'warn_user' => "Warning sent",
        _ => action,
      };
}
