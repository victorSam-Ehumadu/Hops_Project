// lib/views/admin/admin_dashboard_tab.dart
//
// The admin app's home. Three jobs, in the order they matter on a shift:
//
//   1. Live flares and official alerts happening right now — moved here
//      from the deleted Listening Post tab, because an alert nobody has
//      opened the right tab to see is an alert nobody sees. Detection,
//      signature verification and the alarm all live in AdminBleHub, so
//      this is a pure view and works whether or not this screen is open.
//   2. Anything waiting on a decision — open reports, flagged reporters.
//   3. Aggregate stats, which are context rather than work.
//
// Broadcasting an Official Alert also lives here rather than in the nav
// bar: it's rare, deliberate, and shouldn't have a permanent one-tap seat
// next to the tabs used constantly.
//
// Stats come from a single get_admin_dashboard_stats round trip
// (0008_admin_moderation.sql) — aggregate counts only, consistent with the
// app's stance elsewhere: nothing here identifies who did what.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/views/admin/admin_alert_screen.dart';
import 'package:client/views/admin/admin_settings_screen.dart';

class AdminDashboardTab extends StatefulWidget {
  const AdminDashboardTab({super.key});

  @override
  State<AdminDashboardTab> createState() => _AdminDashboardTabState();
}

class _AdminDashboardTabState extends State<AdminDashboardTab> {
  Map<String, dynamic>? _stats;
  int _flaggedReporters = 0;
  bool _loading = true;
  String? _error;
  String? _username;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Quiet background refresh so the counts don't go stale while the app
    // sits open on a desk for a shift.
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    _username = prefs.getString('my_username');
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
      final stats = await Supabase.instance.client
          .rpc('get_admin_dashboard_stats', params: {'p_hops_token': token}).single();
      int flagged = 0;
      try {
        final f = await Supabase.instance.client
            .rpc('admin_list_flagged_reporters', params: {'p_hops_token': token});
        flagged = (f as List).length;
      } catch (_) {
        // 0015 not applied yet — everything else on this screen still works.
      }
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _flaggedReporters = flagged;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A failed silent refresh keeps the last good numbers on screen
      // instead of replacing a working dashboard with an error.
      if (silent) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load stats — check your connection.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        titleSpacing: 20,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Hops Admin",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
            if (_username != null)
              Text(_username!,
                  style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55))),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: "Settings",
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AdminSettingsScreen()))
                .then((_) => setState(() {})),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            const _LiveAlertsSection(),
            _buildAlertButton(colors),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.cloud_off, size: 32, color: colors.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center),
                      TextButton(onPressed: _load, child: const Text("Retry")),
                    ],
                  ),
                ),
              )
            else ...[
              _buildNeedsAttention(colors),
              _StatGroup(title: "Growth", colors: colors, stats: [
                _Stat("Total users", _stats!['total_users']),
                _Stat("New (7d)", _stats!['new_users_7d']),
                _Stat("New (30d)", _stats!['new_users_30d']),
                _Stat("Verified", _stats!['email_verified_count']),
              ]),
              _StatGroup(title: "Moderation", colors: colors, stats: [
                _Stat("Resolved (30d)", _stats!['resolved_reports_30d']),
                _Stat("Bans (30d)", _stats!['bans_30d']),
                _Stat("Currently banned", _stats!['banned_count']),
              ]),
              _StatGroup(title: "Activity", colors: colors, stats: [
                _Stat("Alerts (30d)", _stats!['alerts_30d']),
                _Stat("Admin actions (30d)", _stats!['actions_30d']),
                _Stat("Admins", _stats!['admin_count']),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAlertButton(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 52,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.red.shade900,
            side: BorderSide(color: Colors.red.shade900.withValues(alpha: 0.5)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: const Icon(Icons.campaign),
          label: const Text("Broadcast Official Alert",
              style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AdminAlertScreen())),
        ),
      ),
    );
  }

  /// The two counts that mean somebody has to do something, pulled out of
  /// the stat grid where a number that needs action looked identical to a
  /// number that's just information.
  Widget _buildNeedsAttention(ColorScheme colors) {
    final openReports = (_stats?['open_reports'] as int?) ?? 0;
    if (openReports == 0 && _flaggedReporters == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          if (openReports > 0)
            Expanded(
              child: _AttentionCard(
                count: openReports,
                label: openReports == 1 ? "open report" : "open reports",
                icon: Icons.flag,
                color: Colors.redAccent,
              ),
            ),
          if (openReports > 0 && _flaggedReporters > 0) const SizedBox(width: 10),
          if (_flaggedReporters > 0)
            Expanded(
              child: _AttentionCard(
                count: _flaggedReporters,
                label: _flaggedReporters == 1 ? "flagged reporter" : "flagged reporters",
                icon: Icons.person_off_outlined,
                color: Colors.deepPurple,
              ),
            ),
        ],
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  final int count;
  final String label;
  final IconData icon;
  final Color color;

  const _AttentionCard(
      {required this.count, required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text("$count",
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: color)),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

/// Live flares/alerts from AdminBleHub. Renders nothing at all when quiet —
/// an empty "no alerts" panel at the top of every shift is just noise, and
/// its absence is the same information.
class _LiveAlertsSection extends StatelessWidget {
  const _LiveAlertsSection();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, LiveAlert>>(
      valueListenable: AdminBleHub.instance.liveAlerts,
      builder: (context, alertMap, _) {
        if (alertMap.isEmpty) return const SizedBox.shrink();
        final alerts = alertMap.values.toList()
          ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Row(
                  children: [
                    const Icon(Icons.sensors, size: 15, color: Colors.redAccent),
                    const SizedBox(width: 6),
                    Text("LIVE NEARBY",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                          color: Colors.red.shade900,
                        )),
                  ],
                ),
              ),
              ...alerts.map((a) => _AlertTile(alert: a)),
            ],
          ),
        );
      },
    );
  }
}

class _AlertTile extends StatelessWidget {
  final LiveAlert alert;
  const _AlertTile({required this.alert});

  @override
  Widget build(BuildContext context) {
    final isOfficial = alert.kind == AlertKind.official;
    final color = isOfficial ? Colors.red.shade900 : Colors.orange.shade800;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.35)),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(isOfficial ? Icons.campaign : Icons.warning_amber_rounded, color: color),
        ),
        title: Text(alert.sender, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          isOfficial && alert.adminTitle != null
              ? "${alert.adminTitle} · ${alert.reason}"
              : "${isOfficial ? 'Official Alert' : 'Personal SOS'} · ${alert.reason}",
        ),
        trailing: _VerifyBadge(state: alert.verify),
      ),
    );
  }
}

class _VerifyBadge extends StatelessWidget {
  final AlertVerifyState state;
  const _VerifyBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case AlertVerifyState.verified:
        return const Tooltip(
          message: "Signature verified against a known account",
          child: Icon(Icons.verified, color: Colors.green, size: 20),
        );
      case AlertVerifyState.failed:
        return const Tooltip(
          message: "Signature could not be verified — treat with caution",
          child: Icon(Icons.gpp_bad, color: Colors.redAccent, size: 20),
        );
      case AlertVerifyState.pending:
        return const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
    }
  }
}

class _Stat {
  final String label;
  final dynamic value;
  const _Stat(this.label, this.value);
}

class _StatGroup extends StatelessWidget {
  final String title;
  final ColorScheme colors;
  final List<_Stat> stats;
  const _StatGroup({required this.title, required this.colors, required this.stats});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
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
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: stats
                    .map((s) => Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("${s.value ?? 0}",
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: colors.onSurface)),
                              const SizedBox(height: 2),
                              Text(s.label,
                                  style: TextStyle(
                                      fontSize: 10.5, color: colors.onSurface.withValues(alpha: 0.6))),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
