// lib/views/admin/admin_action_log_tab.dart
//
// Read-only audit trail — every ban/unban/delete/promote/demote/report-
// resolution/official-alert/emergency-flare/warning any admin or student
// has triggered, via list_admin_actions_log (0008_admin_moderation.sql,
// extended in 0010_notifications_and_logging.sql to also carry personal
// Emergency Flares and warnings). No filtering UI yet (chronological only);
// worth adding a by-admin/by-action filter once this list is long enough
// to need one.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
          .rpc('list_admin_actions_log', params: {'p_hops_token': token});
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
          _error = "Couldn't load the action log — check your connection.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Action Log", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh")],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _entries.isEmpty
                  ? Center(
                      child: Text("No admin actions yet.", style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5))))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = _entries[i];
                        final action = e['action'] as String? ?? '';
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(_iconFor(action), color: _colorFor(action)),
                          title: Text(_describe(e), style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            _formatTimestamp(e['created_at'] as String?),
                            style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                          ),
                          trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withValues(alpha: 0.3)),
                          onTap: () => _showDetail(e),
                        );
                      },
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
