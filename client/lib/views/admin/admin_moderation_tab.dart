// lib/views/admin/admin_moderation_tab.dart
//
// Open content_reports queue — students file these via
// lib/utils/report_content.dart (Community Alerts, Vibe Check). Resolving one
// here doesn't remove the reported content from anyone's device (see that
// file's header comment for why: chat/vibe-check content is otherwise
// transient/local-only, this snapshot is the only copy that ever reached
// the server) — it records a decision and, optionally, acts on the
// reported account via ban_user/admin_delete_user.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns a failed moderation RPC into something that actually says what
/// went wrong. Every action in this file used to report the same
/// "Failed — check your connection", which was actively misleading: the
/// most common real cause has nothing to do with connectivity. The RPCs
/// raise named exceptions (see 0008/0010 migrations) precisely so the
/// client can tell these apart.
String describeModerationError(Object e) {
  if (e is PostgrestException) {
    final msg = e.message;
    if (msg.contains('user_not_found')) {
      return "No account by that name exists. If the message shows a sender like "
          "\"ab12?\", that sender couldn't be matched to a real account — the "
          "reporting device hadn't synced the user directory when it filed the report.";
    }
    if (msg.contains('no_attributable_sender')) {
      return "This report has no sender attached (Vibe Check tags are anonymous), so there's nobody to warn.";
    }
    if (msg.contains('report_not_open')) {
      return "This report was already resolved — refresh to update the list.";
    }
    if (msg.contains('report_not_found')) {
      return "This report no longer exists — refresh to update the list.";
    }
    if (msg.contains('not_authorized')) {
      return "Your admin session isn't valid anymore. Sign out and back in.";
    }
    if (msg.contains('cannot_delete_admin')) {
      return "You can't delete an admin account — demote it first.";
    }
    // A missing function surfaces as PGRST202 — almost always means a
    // migration hasn't been applied to this Supabase project yet, which
    // is worth saying outright rather than blaming the network.
    if (e.code == 'PGRST202' || msg.contains('does not exist')) {
      return "This action isn't available on the server yet — the latest database migration hasn't been applied.";
    }
    return "Server rejected the action: $msg";
  }
  return "Couldn't reach the server — check your connection.";
}

class AdminModerationTab extends StatefulWidget {
  const AdminModerationTab({super.key});

  @override
  State<AdminModerationTab> createState() => _AdminModerationTabState();
}

class _AdminModerationTabState extends State<AdminModerationTab> {
  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;
  String? _error;
  final Set<String> _actingOn = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('saved_hops_token');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final token = await _token();
    if (token == null) {
      setState(() {
        _loading = false;
        _error = "Not signed in.";
      });
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .rpc('list_open_reports', params: {'p_hops_token': token});
      setState(() {
        _reports = (rows as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = "Couldn't load reports — check your connection.";
      });
    }
  }

  Future<void> _resolve(String reportId, String status, String actionLabel) async {
    setState(() => _actingOn.add(reportId));
    final token = await _token();
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('resolve_report', params: {
        'p_hops_token': token,
        'p_report_id': reportId,
        'p_status': status,
        'p_action_taken': actionLabel,
      });
      if (mounted) {
        setState(() => _reports.removeWhere((r) => r['id'] == reportId));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(describeModerationError(e)),
            duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(reportId));
    }
  }

  Future<void> _dismiss(Map<String, dynamic> report) =>
      _resolve(report['id'] as String, 'dismissed', 'Dismissed');

  // Vibe Check tags carry no sender at all (see _contentTypeLabel/the tile
  // comment below), so there's nobody "Send warning"/"Ban sender" could
  // ever target — without this, a report on one of those had only
  // Dismiss, with no way to close it as "yes, this needed acting on"
  // rather than "no issue here". Kept narrowly for exactly that case
  // rather than restoring it everywhere: for an attributable report,
  // "action taken" should mean the warning actually went out, not a status
  // label with nobody told anything.
  Future<void> _markReviewed(Map<String, dynamic> report) =>
      _resolve(report['id'] as String, 'actioned', 'Content actioned');

  Future<void> _warnSender(Map<String, dynamic> report) async {
    final username = report['target_username'] as String?;
    if (username == null) return;
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Warn $username?"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("They'll see the reported message, where and when it was sent, and what it violated in their Notifications."),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(
                labelText: "Extra note (optional)",
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade800, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Send warning"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _actingOn.add(report['id'] as String));
    final token = await _token();
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('warn_user_for_report', params: {
        'p_hops_token': token,
        'p_report_id': report['id'],
        if (noteController.text.trim().isNotEmpty) 'p_note': noteController.text.trim(),
      });
      if (mounted) {
        setState(() => _reports.removeWhere((r) => r['id'] == report['id']));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(describeModerationError(e)),
            duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(report['id']));
    }
  }

  Future<void> _banSender(Map<String, dynamic> report) async {
    final username = report['target_username'] as String?;
    if (username == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Ban $username?"),
        content: const Text("This bans the account that sent the reported content and resolves this report as actioned."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Ban"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _actingOn.add(report['id'] as String));
    final token = await _token();
    if (token == null) return;
    try {
      // Look up the target's id via search (reports only store the
      // username, not the id — see 0008_admin_moderation.sql's
      // content_reports shape) before banning.
      final rows = await Supabase.instance.client.rpc('admin_search_users', params: {
        'p_hops_token': token,
        'p_query': username,
      });
      final match = (rows as List).cast<Map<String, dynamic>>().firstWhere(
            (u) => u['username'] == username,
            orElse: () => {},
          );
      if (match.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Couldn't find an account named \"$username\" — it may have already been deleted.")));
        }
        return;
      }
      await Supabase.instance.client.rpc('ban_user', params: {
        'p_hops_token': token,
        'p_target_id': match['id'],
        'p_reason': "Reported content",
      });
      await _resolve(report['id'] as String, 'actioned', 'Sender banned');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(describeModerationError(e)),
            duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(report['id']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Reports", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh")],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _reports.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.flag_outlined, size: 36, color: colors.onSurface.withValues(alpha: 0.2)),
                          const SizedBox(height: 8),
                          Text("No open reports.", style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5))),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _reports.length,
                      itemBuilder: (context, i) {
                        final r = _reports[i];
                        final id = r['id'] as String;
                        final acting = _actingOn.contains(id);
                        final targetUsername = r['target_username'] as String?;
                        final contentType = r['content_type'] as String? ?? '';
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _CategoryChip(category: r['category'] as String? ?? 'other'),
                                    const SizedBox(width: 8),
                                    Text(_contentTypeLabel(contentType),
                                        style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5))),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  r['snapshot_text'] as String? ?? '',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  targetUsername != null
                                      ? "From: $targetUsername · reported by ${r['reporter_username']}"
                                      : "Reported by ${r['reporter_username']} (no attributable sender — see file header comment)",
                                  style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                                ),
                                const SizedBox(height: 6),
                                // Two distinct times that are easy to
                                // conflate: when the content was actually
                                // sent, vs. when someone got around to
                                // reporting it. They can be hours apart.
                                _TimeRow(
                                  icon: Icons.schedule,
                                  label: "Sent",
                                  iso: r['content_created_at'] as String?,
                                  fallback: "unknown (reported before this was recorded)",
                                ),
                                _TimeRow(
                                  icon: Icons.flag_outlined,
                                  label: "Reported",
                                  iso: r['created_at'] as String?,
                                ),
                                const SizedBox(height: 12),
                                if (acting)
                                  const Align(
                                    alignment: Alignment.centerRight,
                                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                  )
                                else
                                  Wrap(
                                    spacing: 8,
                                    alignment: WrapAlignment.end,
                                    children: [
                                      TextButton(onPressed: () => _dismiss(r), child: const Text("Dismiss")),
                                      // Was two buttons for an attributable report:
                                      // "Mark actioned" (recorded a decision but told
                                      // the reported sender nothing — a report could
                                      // be closed as "actioned" with no message ever
                                      // reaching anyone) sitting next to a separate
                                      // "Warn sender" that did the actual work. One
                                      // button that does the real thing, named for
                                      // what it does. "Mark reviewed" survives only
                                      // for reports with nobody to warn (see
                                      // _markReviewed).
                                      if (targetUsername != null) ...[
                                        TextButton(
                                          onPressed: () => _warnSender(r),
                                          style: TextButton.styleFrom(foregroundColor: Colors.amber.shade800),
                                          child: const Text("Send warning"),
                                        ),
                                        TextButton(
                                          onPressed: () => _banSender(r),
                                          style: TextButton.styleFrom(foregroundColor: Colors.red.shade900),
                                          child: const Text("Ban sender"),
                                        ),
                                      ] else
                                        TextButton(
                                          onPressed: () => _markReviewed(r),
                                          child: const Text("Mark reviewed"),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }

  String _contentTypeLabel(String contentType) {
    switch (contentType) {
      case 'chat_message':
        return "Community Alerts";
      case 'vibe_check':
        return "Vibe Check";
      case 'contact_profile':
        return "Profile";
      default:
        return contentType;
    }
  }
}

class _TimeRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? iso;
  final String? fallback;
  const _TimeRow({
    required this.icon,
    required this.label,
    required this.iso,
    this.fallback,
  });

  String _format(String value) {
    final dt = DateTime.tryParse(value)?.toLocal();
    if (dt == null) return value;
    String two(int n) => n.toString().padLeft(2, '0');
    final absolute =
        "${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}";

    // Absolute time is what an admin needs to act on (it goes into the
    // warning the student receives), but a relative hint makes "is this
    // still current?" readable at a glance.
    final diff = DateTime.now().difference(dt);
    final String relative;
    if (diff.inMinutes < 1) {
      relative = "just now";
    } else if (diff.inHours < 1) {
      relative = "${diff.inMinutes}m ago";
    } else if (diff.inDays < 1) {
      relative = "${diff.inHours}h ago";
    } else {
      relative = "${diff.inDays}d ago";
    }
    return "$absolute · $relative";
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final value = iso;
    if (value == null && fallback == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: colors.onSurface.withValues(alpha: 0.4)),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              "$label: ${value != null ? _format(value) : fallback!}",
              style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55)),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String category;
  const _CategoryChip({required this.category});

  static const _labels = {
    'spam': 'Spam',
    'harassment': 'Harassment',
    'inappropriate': 'Inappropriate',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(_labels[category] ?? category,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: colors.primary)),
    );
  }
}
