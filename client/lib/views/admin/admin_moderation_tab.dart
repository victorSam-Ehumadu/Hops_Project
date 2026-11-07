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
import 'package:client/views/admin/admin_user_detail_screen.dart';
import 'package:client/utils/admin_error_text.dart';

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
        _error = describeAdminError(e, fallbackSubject: "reports");
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

  /// Resolves a username to an account id.
  ///
  /// Reports store the username only (see 0008_admin_moderation.sql's
  /// content_reports shape), so anything that needs an id has to look it
  /// up. Factored out of _banSender, which had this inline, so the new
  /// Take Action button cannot drift from it.
  Future<String?> _lookUpUserId(String username) async {
    final token = await _token();
    if (token == null) return null;
    final rows = await Supabase.instance.client.rpc('admin_search_users',
        params: {'p_hops_token': token, 'p_query': username});
    final match = (rows as List).cast<Map<String, dynamic>>().firstWhere(
          (u) => u['username'] == username,
          orElse: () => {},
        );
    return match.isEmpty ? null : match['id'] as String?;
  }

  /// Opens the account screen's own Take Action sheet for the REPORTED
  /// user, with its flag entry pointed at the REPORTER.
  ///
  /// Deliberately the real screen rather than a second sheet built here.
  /// The sheet's contents depend on the target's loaded state — banned,
  /// suspended, already an admin — so a copy would need this tab to fetch
  /// and track all of that too, and would be one more place to forget when
  /// an action is added.
  Future<void> _takeActionOnReport(Map<String, dynamic> report) async {
    final reported = report['target_username'] as String?;
    if (reported == null) return;
    final reporter = report['reporter_username'] as String?;

    setState(() => _actingOn.add(report['id'] as String));
    try {
      final reportedId = await _lookUpUserId(reported);
      if (reportedId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Couldn\'t find an account named "$reported" — '
                  'it may have already been deleted.')));
        }
        return;
      }
      // Best-effort: a missing reporter only costs the flag entry its
      // separate target, and the sheet still opens for the reported user.
      final reporterId =
          reporter == null ? null : await _lookUpUserId(reporter);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminUserDetailScreen(
          userId: reportedId,
          username: reported,
          autoOpenActions: true,
          flagTargetUserId: reporterId,
          flagTargetUsername: reporterId == null ? null : reporter,
        ),
      ));
      // Moderating from here can ban or delete the reported account, which
      // changes what the open reports should say.
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(describeModerationError(e)),
            duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(report['id'] as String));
    }
  }

  /// Take Action on a report with NO attributable sender.
  ///
  /// Vibe Check tags, Study Bunny tags and Lost & Found posts carry no
  /// sender by design, so there is genuinely nobody to warn, suspend or
  /// ban. The one account a moderator can still act on is the person who
  /// filed it — which matters, because an anonymous surface is exactly
  /// where a malicious report costs the reporter nothing. So this opens the
  /// sheet for the REPORTER, with its flag entry pointed at them.
  ///
  /// On return it offers to close the report as "actioned" rather than
  /// doing it automatically: opening the sheet is not the same as having
  /// decided something, and an admin who backs out should not find the
  /// report silently closed behind them.
  Future<void> _takeActionOnReporter(Map<String, dynamic> report) async {
    final reporter = report['reporter_username'] as String?;
    if (reporter == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('This report has neither a sender nor a reporter '
                'on record, so there is nobody to act on. Dismiss it.')));
      }
      return;
    }

    setState(() => _actingOn.add(report['id'] as String));
    try {
      final reporterId = await _lookUpUserId(reporter);
      if (reporterId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text("No account named $reporter exists "
                  "- it may already have been deleted.")));
        }
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminUserDetailScreen(
          userId: reporterId,
          username: reporter,
          autoOpenActions: true,
          // The sheet is already theirs, so the flag entry targets the
          // same account rather than a second one.
          flagTargetUserId: reporterId,
          flagTargetUsername: reporter,
        ),
      ));
      if (!mounted) return;
      _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Close this report as actioned?'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'CLOSE',
          onPressed: () => _markReviewed(report),
        ),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(describeModerationError(e)),
            duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(report['id'] as String));
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
                                // What the reporter wrote themselves.
                                // Visually distinct from snapshot_text
                                // above, which is the reported CONTENT —
                                // conflating the two would be bad, since
                                // one is evidence and the other is an
                                // account of it. Only rendered when
                                // present: the field is optional, and
                                // every report filed before the note
                                // existed has none.
                                if ((r['note'] as String?)?.trim().isNotEmpty
                                    ?? false) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: colors.primary
                                          .withValues(alpha: 0.07),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border(
                                        left: BorderSide(
                                            color: colors.primary, width: 3),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "REPORTER'S NOTE",
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            letterSpacing: 0.7,
                                            fontWeight: FontWeight.w700,
                                            color: colors.primary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          (r['note'] as String).trim(),
                                          style: const TextStyle(
                                              fontSize: 13, height: 1.4),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 8),
                                // WHO WAS REPORTED, said plainly. This was
                                // an 11px line at half opacity reading
                                // "From: <name>", which is the one fact a
                                // moderator needs first and the easiest
                                // label to misread as a chat sender rather
                                // than the subject of the report.
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: targetUsername != null
                                        ? Colors.red.shade900
                                            .withValues(alpha: 0.07)
                                        : colors.onSurface
                                            .withValues(alpha: 0.05),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        targetUsername != null
                                            ? Icons.person_outline
                                            : Icons.person_off_outlined,
                                        size: 15,
                                        color: targetUsername != null
                                            ? Colors.red.shade900
                                            : colors.onSurface
                                                .withValues(alpha: 0.45),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              targetUsername != null
                                                  ? 'Reported user: $targetUsername'
                                                  : 'Reported user: not identified',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
                                                color: targetUsername != null
                                                    ? Colors.red.shade900
                                                    : colors.onSurface
                                                        .withValues(
                                                            alpha: 0.7),
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              targetUsername != null
                                                  ? 'Filed by ${r['reporter_username']}'
                                                  : 'Filed by ${r['reporter_username']} · this content type carries no sender, so there is nobody to act against',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: colors.onSurface
                                                    .withValues(alpha: 0.6),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
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
                                        // Everything else on this row is a
                                        // single decision. This opens the
                                        // full sheet for the reported user
                                        // — suspend, promote, delete, flag
                                        // the reporter — without leaving
                                        // the queue to find them.
                                        TextButton.icon(
                                          onPressed: () => _takeActionOnReport(r),
                                          icon: const Icon(Icons.more_horiz, size: 18),
                                          label: const Text("Take action"),
                                        ),
                                      ] else
                                        // "Mark reviewed" is gone. It was
                                        // the only control on a report with
                                        // no attributable sender, which made
                                        // the queue look like it could do
                                        // nothing — and it closed the report
                                        // without recording a decision about
                                        // anyone. Take action is now on every
                                        // report. With no sender to act
                                        // against it opens the sheet for the
                                        // REPORTER instead, which is the one
                                        // account a moderator can still do
                                        // something about: flag them for
                                        // wrongful reporting, or warn them.
                                        TextButton.icon(
                                          onPressed: () =>
                                              _takeActionOnReporter(r),
                                          icon: const Icon(Icons.more_horiz,
                                              size: 18),
                                          label: const Text("Take action"),
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
