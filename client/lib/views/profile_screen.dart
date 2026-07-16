import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/theme/hops_theme.dart';
import 'package:client/views/root_gatekeeper.dart';

class HopsProfileScreen extends StatefulWidget {
  const HopsProfileScreen({super.key});
  @override
  State<HopsProfileScreen> createState() => _HopsProfileScreenState();
}

class _HopsProfileScreenState extends State<HopsProfileScreen> {
  String dynamicProfileUsername = "Loading Node...";
  String dynamicProfileNodeUuid = "hops-node-calculating...";

  @override
  void initState() {
    super.initState();
    _loadPersistedIdentityStrings();
  }

  Future<void> _loadPersistedIdentityStrings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      dynamicProfileUsername = prefs.getString('my_username') ?? 'Mesh_Operator';
      dynamicProfileNodeUuid = prefs.getString('my_hops_id') ?? 'hops-node-unassigned';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile Identity", style: TextStyle(fontWeight: FontWeight.bold)), elevation: 0, backgroundColor: Colors.transparent),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const CircleAvatar(radius: 48, backgroundColor: HopsTheme.primaryContainer, child: Icon(Icons.person, size: 48, color: Colors.white)),
            const SizedBox(height: 16),
            Text(dynamicProfileUsername, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: HopsTheme.primary)),
            const Text("BScIT Node Operator", style: TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: HopsTheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
              child: Row(
                children: [
                  const Icon(Icons.badge, color: HopsTheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Node ID", style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                        SelectableText(dynamicProfileNodeUuid, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                      ],
                    ),
                  )
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(color: HopsTheme.surfaceContainerHighest),
            const SizedBox(height: 8),
            const Align(alignment: Alignment.centerLeft, child: Text("SETTINGS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: HopsTheme.primary, letterSpacing: 1.2))),
            const SizedBox(height: 8),
            _buildSettingsOption(Icons.security, "Cryptographic Key Management", "View and cycle your 2048-bit RSA keys"),
            _buildSettingsOption(Icons.radio, "Mesh Relay Strategy", "Configure background radio data hopping preferences"),
            _buildSettingsOption(Icons.notifications_none, "Local Notifications", "Manage offline ping reminders"),
            const SizedBox(height: 24),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              color: Colors.red.withOpacity(0.05),
              elevation: 0,
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text("Log Out / Destroy Identity", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text("Clears local storage preferences and destroys local keys."),
                onTap: () async {
                  final db = await DatabaseHelper.instance.database;
                  final dbPath = await getDatabasesPath();
                  await deleteDatabase(p.join(dbPath, 'MeshNetwork.db'));
                  final SharedPreferences prefs = await SharedPreferences.getInstance();
                  await prefs.remove('saved_hops_token');
                  const FlutterSecureStorage().delete(key: 'private_key');
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()),
                          (route) => false,
                    );
                  }
                },
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsOption(IconData icon, String title, String subtitle) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Icon(icon, color: HopsTheme.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 18),
    );
  }
}