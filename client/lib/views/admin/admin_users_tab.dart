// lib/views/admin/admin_users_tab.dart
//
// Find an account, then open it.
//
// Previously each search result carried Ban / Delete / Promote / Demote
// buttons inline, which put four irreversible actions on a scrolling list
// and offered no history to justify any of them. The list is now just
// identity; everything you can *do* lives behind a tap, on
// admin_user_detail_screen.dart, where the account's record is on screen
// next to the actions.
//
// Second mode: reporters flagged for repeatedly filing reports that were
// dismissed (see 0015_admin_management.sql). That queue needs somewhere to
// live and this is the tab about people.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/views/admin/admin_user_detail_screen.dart';

class AdminUsersTab extends StatefulWidget {
  const AdminUsersTab({super.key});

  @override
  State<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _AdminUsersTabState extends State<AdminUsersTab> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _flagged = [];
  bool _loading = true;
  bool _showFlagged = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
      final rows = await Supabase.instance.client.rpc('admin_search_users', params: {
        'p_hops_token': token,
        'p_query': _searchController.text.trim(),
      });
      // Fetched alongside the search so the flag count on the toggle is
      // always live, whichever mode you're looking at.
      List<Map<String, dynamic>> flagged = [];
      try {
        final f = await Supabase.instance.client
            .rpc('admin_list_flagged_reporters', params: {'p_hops_token': token});
        flagged = (f as List).cast<Map<String, dynamic>>();
      } catch (_) {
        // Migration 0015 not applied yet — the rest of the tab still works,
        // so this shouldn't take the whole screen down with it.
      }
      if (!mounted) return;
      setState(() {
        _users = (rows as List).cast<Map<String, dynamic>>();
        _flagged = flagged;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load users — check your connection.";
      });
    }
  }

  Future<void> _open(String id, String username) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AdminUserDetailScreen(userId: id, username: username),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final list = _showFlagged ? _flagged : _users;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Users", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh"),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              onSubmitted: (_) {
                setState(() => _showFlagged = false);
                _load();
              },
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: "Search by username or email",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text("All"),
                  selected: !_showFlagged,
                  onSelected: (_) => setState(() => _showFlagged = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: _flagged.isEmpty
                      ? null
                      : const Icon(Icons.flag, size: 15, color: Colors.deepPurple),
                  label: Text(_flagged.isEmpty
                      ? "Flagged reporters"
                      : "Flagged reporters (${_flagged.length})"),
                  selected: _showFlagged,
                  onSelected: (_) => setState(() => _showFlagged = true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : list.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_showFlagged ? Icons.flag_outlined : Icons.person_search,
                                      size: 36, color: colors.onSurface.withValues(alpha: 0.2)),
                                  const SizedBox(height: 10),
                                  Text(
                                    _showFlagged
                                        ? "No one is flagged for wrongful reporting."
                                        : "No matching users.",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: list.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, i) => _UserRow(
                              user: list[i],
                              flaggedMode: _showFlagged,
                              onTap: () => _open(
                                list[i]['id'] as String,
                                list[i]['username'] as String? ?? '',
                              ),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool flaggedMode;
  final VoidCallback onTap;

  const _UserRow({required this.user, required this.flaggedMode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final banned = user['banned'] as bool? ?? false;
    final isAdmin = (user['role'] as String? ?? 'student') == 'admin';
    final suspendedUntil = DateTime.tryParse(user['suspended_until'] as String? ?? '');
    final suspended = suspendedUntil != null && suspendedUntil.isAfter(DateTime.now());
    final username = user['username'] as String? ?? '';

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: isAdmin
              ? colors.primary
              : banned
                  ? Colors.red.withValues(alpha: 0.15)
                  : colors.primary.withValues(alpha: 0.1),
          child: Icon(
            isAdmin ? Icons.shield : Icons.person,
            size: 20,
            color: isAdmin
                ? Colors.white
                : banned
                    ? Colors.redAccent
                    : colors.primary,
          ),
        ),
        title: Text(username,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            overflow: TextOverflow.ellipsis),
        subtitle: Text(
          flaggedMode
              ? "${user['dismissed_reports_count'] ?? 0} dismissed reports "
                  "of ${user['reports_filed'] ?? 0} filed"
              : (user['email'] as String? ?? ''),
          style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isAdmin) _chip("Admin", colors.primary),
            if (banned) _chip("Banned", Colors.redAccent),
            if (suspended) _chip("Suspended", Colors.orange.shade800),
            if (flaggedMode) _chip("Flagged", Colors.deepPurple),
            Icon(Icons.chevron_right, size: 20, color: colors.onSurface.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
      );
}
