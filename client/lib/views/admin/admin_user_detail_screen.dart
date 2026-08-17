// lib/views/admin/admin_user_detail_screen.dart
//
// Everything known about one account, and every action that can be taken
// against it. Reached by tapping a row in the Users tab.
//
// Why this exists as its own screen: the Users tab used to put Ban, Delete,
// Promote and Demote directly on each search result, so an irreversible
// action was one mistap away from a list you scroll — with none of the
// history that should inform it. Now the list is just names, and acting on
// someone requires opening them, reading their record, and confirming.
//
// Every action here is logged server-side (admin_actions_log) by the RPC
// itself, not by this screen, so the audit trail can't be skipped by a
// client that forgets to write it.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminUserDetailScreen extends StatefulWidget {
  final String userId;
  final String username;

  const AdminUserDetailScreen({
    super.key,
    required this.userId,
    required this.username,
  });

  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  bool _acting = false;
  String? _error;
  String? _myUsername;

  /// True once anything was changed, so the Users tab behind knows to
  /// refresh rather than showing a stale "not banned" row.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _token() async {
    final prefs = await SharedPreferences.getInstance();
    _myUsername ??= prefs.getString('my_username');
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
      final detail = await Supabase.instance.client.rpc('admin_get_user_detail', params: {
        'p_hops_token': token,
        'p_target_id': widget.userId,
      }).single();
      final history = await Supabase.instance.client.rpc('admin_get_user_history', params: {
        'p_hops_token': token,
        'p_target_id': widget.userId,
      });
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _history = (history as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load this account — check your connection.";
      });
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────

  /// Returns whether the action actually succeeded — callers that follow up
  /// with a notification email (see _sendModerationEmail) need to know this
  /// rather than assuming success, or a ban that failed (self-ban, a
  /// missing migration, no connection) would still tell the target by
  /// email that they'd been banned.
  Future<bool> _run(String label, Future<void> Function(String token) action) async {
    setState(() => _acting = true);
    try {
      final token = await _token();
      if (token == null) return false;
      await action(token);
      _changed = true;
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("$label — done, and recorded in the log.")));
      }
      return true;
    } on PostgrestException catch (e) {
      if (!mounted) return false;
      String message = "Action failed.";
      if (e.message.contains('cannot_delete_admin')) {
        message = "Demote this account before deleting it.";
      } else if (e.message.contains('cannot_demote_self')) {
        message = "You can't demote your own account.";
      } else if (e.message.contains('cannot_ban_self') ||
          e.message.contains('cannot_suspend_self')) {
        message = "You can't do that to your own account.";
      } else if (e.message.contains('does not exist')) {
        message = "Server missing this action — run migration 0015.";
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return false;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Action failed — check your connection.")));
      }
      return false;
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  /// Best-effort notification email — see supabase/functions/
  /// send-moderation-email/. Never surfaces a generic failure: the
  /// moderation action this follows has already succeeded and recorded
  /// itself in the log by the time this runs, so a Resend outage or a
  /// missing RESEND_API_KEY secret shouldn't read as "something went
  /// wrong with the ban/suspend" — only the one case actionable from this
  /// screen (no email on file at all) gets its own message.
  Future<void> _sendModerationEmail(
    String kind, {
    String? reason,
    DateTime? suspendedUntil,
  }) async {
    try {
      final token = await _token();
      if (token == null) return;
      final res = await Supabase.instance.client.functions.invoke(
        'send-moderation-email',
        body: {
          'admin_hops_token': token,
          'target_id': widget.userId,
          'kind': kind,
          if (reason != null && reason.isNotEmpty) 'reason': reason,
          if (suspendedUntil != null) 'suspended_until': suspendedUntil.toIso8601String(),
        },
      );
      final data = res.data;
      // Previously only 'no_email_on_file' was surfaced — every other
      // failure (Resend rejecting the send, RESEND_API_KEY missing, etc.)
      // came back as {ok:false, error:...} exactly the same way, but was
      // silently dropped, so a ban/suspend could "succeed" here while the
      // target was never actually told, with nothing in the UI to say so.
      // A common real cause for 'send_failed' on this project's setup:
      // Resend's shared onboarding@resend.dev sender only delivers to the
      // Resend account's own verified address until a real sending domain
      // is verified and HOPS_EMAIL_FROM is set — see
      // supabase/functions/_shared/send_email.ts.
      if (mounted && data is Map && data['ok'] == false) {
        final err = data['error'] as String?;
        final message = switch (err) {
          'no_email_on_file' => "No email on file for this account — they won't be emailed about this.",
          'send_failed' => "Done, but the notification email failed to send "
              "(check the Resend sending domain / RESEND_API_KEY).",
          'email_not_configured' => "Done, but no email service is configured "
              "(RESEND_API_KEY isn't set) — they won't be emailed about this.",
          _ => "Done, but the notification email couldn't be sent.",
        };
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      // Not surfaced — see doc comment. The edge function may not even be
      // deployed yet on a project that's only applied the SQL migrations.
      // This branch is for the call itself failing (offline, function not
      // found); a call that succeeds but returns {ok:false} is handled
      // above instead.
    }
  }

  /// Shared confirmation. Every destructive action goes through this —
  /// the point of the Take Action sheet is that nothing on it fires from a
  /// single tap.
  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
    bool destructive = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: destructive ? Colors.red.shade900 : null,
              foregroundColor: destructive ? Colors.white : null,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _ban() async {
    final reasonController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Ban ${widget.username}?"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                "Permanent until an admin lifts it. They're signed out immediately and can't sign back in."),
            const SizedBox(height: 12),
            TextField(
              controller: reasonController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: "Reason (shown to them)",
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Ban"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final reason = reasonController.text.trim();
    final succeeded = await _run(
        "Banned ${widget.username}",
        (token) => Supabase.instance.client.rpc('ban_user', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
              'p_reason': reason.isEmpty ? null : reason,
            }));
    if (succeeded) _sendModerationEmail('ban', reason: reason);
  }

  Future<void> _suspend() async {
    final reasonController = TextEditingController();
    int days = 7;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: Text("Suspend ${widget.username}?"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Locked out until the suspension expires, then it lifts on its own."),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [1, 3, 7, 14, 30]
                    .map((d) => ChoiceChip(
                          label: Text("${d}d"),
                          selected: days == d,
                          onSelected: (_) => setSheet(() => days = d),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: "Reason (shown to them)",
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange.shade900, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Suspend"),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final reason = reasonController.text.trim();
    final succeeded = await _run(
        "Suspended ${widget.username} for $days days",
        (token) => Supabase.instance.client.rpc('suspend_user', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
              'p_days': days,
              'p_reason': reason.isEmpty ? null : reason,
            }));
    if (succeeded) {
      _sendModerationEmail(
        'suspend',
        reason: reason,
        suspendedUntil: DateTime.now().add(Duration(days: days)),
      );
    }
  }

  Future<void> _promote() async {
    if (!await _confirm(
      title: "Make ${widget.username} an admin?",
      body: "They'll be able to ban accounts, broadcast campus-wide alerts, "
          "see real usernames on reports, and promote other admins.",
      confirmLabel: "Make admin",
      destructive: false,
    )) {
      return;
    }
    await _run("${widget.username} is now an admin",
        (token) => Supabase.instance.client.rpc('promote_admin', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
            }));
  }

  Future<void> _demote() async {
    if (!await _confirm(
      title: "Remove admin from ${widget.username}?",
      body: "They keep their account but lose all admin powers, and their "
          "current admin session ends immediately.",
      confirmLabel: "Demote",
    )) {
      return;
    }
    await _run("${widget.username} demoted",
        (token) => Supabase.instance.client.rpc('demote_admin', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
            }));
  }

  Future<void> _delete() async {
    // Two gates, not one: this is the only action here that destroys data
    // rather than changing a flag, and it cannot be undone from anywhere in
    // the app.
    if (!await _confirm(
      title: "Delete ${widget.username}?",
      body: "Permanently deletes the account. This cannot be undone.",
      confirmLabel: "Continue",
    )) {
      return;
    }
    if (!mounted) return;

    final typed = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Type the username to confirm"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Type ${widget.username} exactly to delete this account."),
            const SizedBox(height: 12),
            TextField(
              controller: typed,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade900, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete permanently"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (typed.text.trim() != widget.username) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Username didn't match — nothing was deleted.")));
      }
      return;
    }
    await _run("Deleted ${widget.username}",
        (token) => Supabase.instance.client.rpc('admin_delete_user', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
            }));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _clearReporterFlag() async {
    if (!await _confirm(
      title: "Clear reporting flag?",
      body: "Resets ${widget.username}'s dismissed-report count to zero and "
          "removes them from the flagged list. Use this when their reports "
          "were made in good faith.",
      confirmLabel: "Clear flag",
      destructive: false,
    )) {
      return;
    }
    await _run("Reporting flag cleared",
        (token) => Supabase.instance.client.rpc('admin_clear_reporter_flag', params: {
              'p_hops_token': token,
              'p_target_id': widget.userId,
            }));
  }

  void _showActionSheet() {
    final d = _detail;
    if (d == null) return;
    final banned = d['banned'] as bool? ?? false;
    final isAdmin = (d['role'] as String? ?? 'student') == 'admin';
    final isSelf = d['username'] == _myUsername;
    final suspendedUntil = _parseDate(d['suspended_until'] as String?);
    final suspended = suspendedUntil != null && suspendedUntil.isAfter(DateTime.now());

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            const SizedBox(height: 16),
            Text("Take action on ${widget.username}",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 8),
            if (isSelf)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text("This is your own account.", textAlign: TextAlign.center),
              )
            else ...[
              if (banned)
                _action(ctx, Icons.lock_open, "Unban", "Restores full access", Colors.green, () {
                  Navigator.pop(ctx);
                  _run("Unbanned ${widget.username}",
                          (token) => Supabase.instance.client.rpc('unban_user', params: {
                                'p_hops_token': token,
                                'p_target_id': widget.userId,
                              }))
                      .then((ok) {
                    if (ok) _sendModerationEmail('unban');
                  });
                })
              else
                _action(ctx, Icons.gavel, "Ban", "Permanent until lifted", Colors.red.shade900, () {
                  Navigator.pop(ctx);
                  _ban();
                }),
              if (suspended)
                _action(ctx, Icons.timer_off, "End suspension", "Restores access now", Colors.green,
                    () {
                  Navigator.pop(ctx);
                  _run("Suspension lifted",
                          (token) => Supabase.instance.client.rpc('unsuspend_user', params: {
                                'p_hops_token': token,
                                'p_target_id': widget.userId,
                              }))
                      .then((ok) {
                    if (ok) _sendModerationEmail('unsuspend');
                  });
                })
              else
                _action(ctx, Icons.timelapse, "Suspend", "Temporary, lifts on its own",
                    Colors.orange.shade900, () {
                  Navigator.pop(ctx);
                  _suspend();
                }),
              if (isAdmin)
                _action(ctx, Icons.remove_moderator, "Remove admin", "Back to a normal account",
                    Colors.orange.shade800, () {
                  Navigator.pop(ctx);
                  _demote();
                })
              else
                _action(ctx, Icons.add_moderator, "Make admin", "Full moderation powers",
                    Theme.of(ctx).colorScheme.primary, () {
                  Navigator.pop(ctx);
                  _promote();
                }),
              if ((d['reporter_flagged_at'] as String?) != null)
                _action(ctx, Icons.flag_outlined, "Clear reporting flag",
                    "Resets their dismissed-report count", Colors.blueGrey, () {
                  Navigator.pop(ctx);
                  _clearReporterFlag();
                }),
              if (!isAdmin)
                _action(ctx, Icons.delete_forever, "Delete account", "Permanent, cannot be undone",
                    Colors.red.shade900, () {
                  Navigator.pop(ctx);
                  _delete();
                }),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext ctx, IconData icon, String title, String subtitle, Color color,
          VoidCallback onTap) =>
      ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle,
            style: TextStyle(
                fontSize: 11, color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.55))),
        onTap: onTap,
      );

  // ── View ───────────────────────────────────────────────────────────────

  static DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso)?.toLocal();

  static String _fmtDate(String? iso) {
    final dt = _parseDate(iso);
    if (dt == null) return "—";
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.username,
              style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
          elevation: 0,
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh"),
          ],
        ),
        floatingActionButton: (_detail == null || _acting)
            ? null
            : FloatingActionButton.extended(
                onPressed: _showActionSheet,
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text("Take action"),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
                : _buildBody(colors),
      ),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    final d = _detail!;
    final banned = d['banned'] as bool? ?? false;
    final suspendedUntil = _parseDate(d['suspended_until'] as String?);
    final suspended = suspendedUntil != null && suspendedUntil.isAfter(DateTime.now());
    final isAdmin = (d['role'] as String? ?? 'student') == 'admin';
    final flagged = d['reporter_flagged_at'] != null;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          // Standing first, before anything else — it's the thing that
          // changes what you're about to do.
          if (banned)
            _Banner(
              color: Colors.red.shade900,
              icon: Icons.block,
              title: "Banned",
              body: [
                if ((d['ban_reason'] as String?)?.isNotEmpty == true) "Reason: ${d['ban_reason']}",
                "Since ${_fmtDate(d['banned_at'] as String?)}",
              ].join("\n"),
            )
          else if (suspended)
            _Banner(
              color: Colors.orange.shade900,
              icon: Icons.timelapse,
              title: "Suspended until ${_fmtDate(d['suspended_until'] as String?)}",
              body: (d['suspension_reason'] as String?)?.isNotEmpty == true
                  ? "Reason: ${d['suspension_reason']}"
                  : "Lifts automatically.",
            )
          else
            _Banner(
              color: Colors.green.shade800,
              icon: Icons.check_circle_outline,
              title: "Account in good standing",
              body: "No active ban or suspension.",
            ),

          if (flagged)
            _Banner(
              color: Colors.deepPurple,
              icon: Icons.flag,
              title: "Flagged for wrongful reporting",
              body: "${d['dismissed_reports_count'] ?? 0} of their reports were dismissed. "
                  "Decide whether to act or clear the flag.",
            ),

          const SizedBox(height: 4),
          _Section(title: "Account", children: [
            _Row(label: "Username", value: d['username'] as String? ?? "—"),
            _Row(label: "Email", value: d['email'] as String? ?? "—"),
            _Row(
                label: "Email verified",
                value: (d['email_verified'] as bool? ?? false) ? "Yes" : "No"),
            _Row(label: "Joined Hops", value: _fmtDate(d['created_at'] as String?)),
            _Row(label: "Role", value: isAdmin ? "Admin" : "Student"),
            if (isAdmin && (d['admin_title'] as String?)?.isNotEmpty == true)
              _Row(label: "Admin title", value: d['admin_title'] as String),
          ]),

          _Section(title: "Record", children: [
            _Row(label: "Times banned", value: "${d['ban_count'] ?? 0}"),
            _Row(label: "Times suspended", value: "${d['suspend_count'] ?? 0}"),
            _Row(label: "Warnings received", value: "${d['warning_count'] ?? 0}"),
            _Row(label: "Reports against them", value: "${d['reports_against'] ?? 0}"),
            _Row(
                label: "…that were upheld",
                value: "${d['reports_actioned_against'] ?? 0}",
                dim: true),
          ]),

          _Section(title: "Reporting behaviour", children: [
            _Row(label: "Reports they filed", value: "${d['reports_filed'] ?? 0}"),
            _Row(
              label: "…dismissed as unfounded",
              value: "${d['dismissed_reports_count'] ?? 0}",
              // 4 is the automatic-warning threshold in resolve_report;
              // showing it in red from there up makes the number mean
              // something without needing a legend.
              alert: ((d['dismissed_reports_count'] as int?) ?? 0) >= 4,
            ),
            _Row(
                label: "Warned about reporting",
                value: d['reporter_warned_at'] == null
                    ? "No"
                    : _fmtDate(d['reporter_warned_at'] as String?)),
          ]),

          _Section(
            title: "Moderation history",
            children: _history.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text("Nothing on record.",
                          style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.5))),
                    )
                  ]
                : _history.map((h) => _HistoryRow(entry: h)).toList(),
          ),
        ],
      ),
    );
  }
}

// ── Small presentational pieces ──────────────────────────────────────────

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  final String body;
  const _Banner(
      {required this.color, required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
                const SizedBox(height: 2),
                Text(body,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
                color: colors.primary.withValues(alpha: 0.8),
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool alert;
  final bool dim;
  const _Row({required this.label, required this.value, this.alert = false, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, color: colors.onSurface.withValues(alpha: dim ? 0.45 : 0.65))),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: alert ? FontWeight.bold : FontWeight.w600,
              color: alert ? Colors.redAccent : colors.onSurface.withValues(alpha: dim ? 0.6 : 1),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _HistoryRow({required this.entry});

  static const _labels = {
    'ban': 'Banned',
    'unban': 'Unbanned',
    'suspend': 'Suspended',
    'unsuspend': 'Suspension lifted',
    'delete_user': 'Account deleted',
    'promote_admin': 'Promoted to admin',
    'demote_admin': 'Admin removed',
    'resolve_report': 'Report resolved',
    'warn_user': 'Warning sent',
    'clear_reporter_flag': 'Reporting flag cleared',
    'official_alert': 'Official alert',
    'emergency_flare': 'Emergency flare',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final action = entry['action'] as String? ?? '';
    final dt = DateTime.tryParse(entry['created_at'] as String? ?? '')?.toLocal();
    final when = dt == null
        ? ''
        : "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
    final snapshot = entry['content_snapshot'] as String?;
    final reason = entry['reason'] as String?;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_labels[action] ?? action,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              Text(when,
                  style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.45))),
            ],
          ),
          Text(
            "by ${entry['actor_username'] ?? 'system'}"
            "${entry['content_place'] != null ? ' · ${entry['content_place']}' : ''}",
            style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
          ),
          if (reason != null && reason.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(reason,
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.75))),
            ),
          if (snapshot != null && snapshot.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('"$snapshot"',
                    style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: colors.onSurface.withValues(alpha: 0.8))),
              ),
            ),
        ],
      ),
    );
  }
}
