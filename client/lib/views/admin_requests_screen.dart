// lib/views/admin_requests_screen.dart
//
// Admin-only approval queue for admin_requests — see
// supabase/migrations/0002_admin_roles.sql. Only ever reached from
// profile_screen.dart when the signed-in account's cached role is
// 'admin'; the RPC itself re-checks that server-side too (see
// list_pending_admin_requests/review_admin_request), so this screen isn't
// the only thing standing between a student and the queue.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminRequestsScreen extends StatefulWidget {
  const AdminRequestsScreen({super.key});

  @override
  State<AdminRequestsScreen> createState() => _AdminRequestsScreenState();
}

class _AdminRequestsScreenState extends State<AdminRequestsScreen> {
  List<Map<String, dynamic>> _requests = [];
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
          .rpc('list_pending_admin_requests', params: {'p_hops_token': token});
      setState(() {
        _requests = (rows as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } on PostgrestException catch (e) {
      setState(() {
        _loading = false;
        _error = e.code == '42501'
            ? "Admin access required."
            : "Couldn't load requests: ${e.message}";
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = "Couldn't load requests — check your connection.";
      });
    }
  }

  Future<void> _review(String requestId, bool approve) async {
    setState(() => _actingOn.add(requestId));
    final token = await _token();
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('review_admin_request', params: {
        'p_hops_token': token,
        'p_request_id': requestId,
        'p_approve': approve,
      });
      if (mounted) {
        setState(() => _requests.removeWhere((r) => r['id'] == requestId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(approve ? "Approved" : "Denied")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _actingOn.remove(requestId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text("Admin Requests",
            style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh"),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _requests.isEmpty
                  ? Center(
                      child: Text(
                        "No pending requests.",
                        style: TextStyle(color: colors.onSurface.withOpacity(0.5)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _requests.length,
                      itemBuilder: (context, index) {
                        final req = _requests[index];
                        final id = req['id'] as String;
                        final username = req['requester_username'] as String? ?? 'Unknown';
                        final note = req['note'] as String?;
                        final acting = _actingOn.contains(id);
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
                                    CircleAvatar(
                                      backgroundColor: colors.primary.withOpacity(0.1),
                                      child: Icon(Icons.person, color: colors.primary),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        username,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                if (note != null && note.trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(note, style: const TextStyle(fontSize: 13)),
                                ],
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: acting ? null : () => _review(id, false),
                                      child: const Text("Deny", style: TextStyle(color: Colors.redAccent)),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: colors.primary,
                                        foregroundColor: Colors.white,
                                      ),
                                      onPressed: acting ? null : () => _review(id, true),
                                      child: acting
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                            )
                                          : const Text("Approve"),
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
}
