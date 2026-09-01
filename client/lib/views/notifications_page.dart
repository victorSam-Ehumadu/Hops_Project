// lib/views/notifications_page.dart
//
// Student-facing inbox for admin-sent notifications — currently just
// warnings (see 0010_notifications_and_logging.sql's user_notifications
// table / warn_user_for_report RPC), reachable from the Contacts tab's app
// bar bell (see hops_app.dart's _buildSharedCustomAppBar). Read entirely
// through Supabase since this is exactly the kind of thing that has to
// reach a specific person regardless of whether they're anywhere near the
// admin who sent it — unlike almost everything else in this app, it can't
// be BLE-mesh-local.
import 'package:flutter/material.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/widgets/hops_background_pattern.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    UnreadTracker.instance.clear(UnreadSource.notifications);
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
          .rpc('list_my_notifications', params: {'p_hops_token': token});
      if (mounted) {
        setState(() {
          _notifications = (rows as List).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
      // Awaited, NOT fire-and-forget. The bell's badge is driven by the
      // unread count that hops_app.dart's _syncIdentityStatus polls every
      // 30s; leaving this write in flight meant that poll could easily
      // read the pre-clear count and light the dot straight back up a
      // moment after it had been dismissed — which is exactly what it did.
      //
      // The list already fetched above keeps rendering each row's own
      // read/unread state from before this call, so opening the page
      // still doesn't retroactively hide which ones were new.
      await Supabase.instance.client
          .rpc('mark_all_notifications_read', params: {'p_hops_token': token});
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Couldn't load notifications — check your connection.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Notifications", style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh")],
      ),
      body: HopsBackgroundPattern(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _notifications.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_none, size: 40, color: colors.onSurface.withValues(alpha: 0.2)),
                            const SizedBox(height: 8),
                            Text("Nothing here yet.", style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5))),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _notifications.length,
                        itemBuilder: (context, i) => _NotificationCard(n: _notifications[i]),
                      ),
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  final Map<String, dynamic> n;
  const _NotificationCard({required this.n});

  static const _violationLabels = {
    'spam': 'Spam',
    'harassment': 'Harassment',
    'inappropriate': 'Inappropriate content',
    'other': 'Other',
  };

  String _fmtTimestamp(String? iso) {
    if (iso == null) return 'Unknown time';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'Unknown time';
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} "
        "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isWarning = n['type'] == 'warning';
    final unread = n['read'] == false;
    final snapshot = n['message_snapshot'] as String?;
    final place = n['place'] as String?;
    final violation = n['violation'] as String?;
    final note = n['note'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: unread ? BorderSide(color: Colors.amber.shade700, width: 1.5) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isWarning ? Icons.report_gmailerrorred : Icons.info_outline,
                    color: isWarning ? Colors.amber.shade800 : colors.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    n['title'] as String? ?? (isWarning ? "Warning" : "Notification"),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                if (unread)
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(color: Colors.amber.shade700, shape: BoxShape.circle),
                  ),
              ],
            ),
            if (snapshot != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('"$snapshot"', style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: colors.onSurface.withValues(alpha: 0.85))),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (place != null) _tag(Icons.forum_outlined, place, colors),
                if (violation != null) _tag(Icons.gavel, _violationLabels[violation] ?? violation, colors),
                _tag(Icons.schedule, _fmtTimestamp(n['occurred_at'] as String? ?? n['created_at'] as String?), colors),
              ],
            ),
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(note, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tag(IconData icon, String label, ColorScheme colors) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: colors.primary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: colors.primary)),
          ],
        ),
      );
}
