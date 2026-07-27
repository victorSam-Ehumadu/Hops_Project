import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/views/theme_picker_screen.dart';
import 'package:client/views/terms_screen.dart';

class HopsProfileScreen extends StatefulWidget {
  const HopsProfileScreen({super.key});
  @override
  State<HopsProfileScreen> createState() => _HopsProfileScreenState();
}

class _HopsProfileScreenState extends State<HopsProfileScreen> {
  String dynamicProfileUsername = "Loading Node...";

  @override
  void initState() {
    super.initState();
    _loadPersistedIdentityStrings();
  }

  Future<void> _loadPersistedIdentityStrings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      dynamicProfileUsername =
          prefs.getString('my_username') ?? 'Mesh_Operator';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Profile Identity",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colors.onBackground),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colors.primary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            CircleAvatar(
                radius: 48,
                backgroundColor: colors.primaryContainer,
                child: const Icon(Icons.person, size: 48, color: Colors.white)),
            const SizedBox(height: 16),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                dynamicProfileUsername,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: colors.primary),
              ),
            ),
            Text(
              "BScIT Node Operator",
              style: TextStyle(
                  fontSize: 14,
                  color: colors.onBackground.withOpacity(0.6)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 32),

            // App Theme button
            ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.palette_outlined, color: colors.primary),
              title: Text(
                'App Theme',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'Change the color scheme',
                style: TextStyle(
                    fontSize: 12,
                    color: colors.onBackground.withOpacity(0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18,
                  color: colors.onBackground),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ThemePickerScreen()));
              },
            ),
            const SizedBox(height: 24),

            // Terms and Conditions button
            ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.description_outlined, color: colors.primary),
              title: Text(
                'Terms and Conditions',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.onBackground),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18,
                  color: colors.onBackground),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const TermsScreen()));
              },
            ),
            const SizedBox(height: 24),

            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              color: Colors.red.withOpacity(0.05),
              elevation: 0,
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  "Log Out / Destroy Identity",
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  "Clears local storage preferences and destroys local keys.",
                  style: TextStyle(
                      color: colors.onBackground.withOpacity(0.7)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  final db = await DatabaseHelper.instance.database;
                  final dbPath = await getDatabasesPath();
                  await deleteDatabase(p.join(dbPath, 'MeshNetwork.db'));
                  final SharedPreferences prefs =
                  await SharedPreferences.getInstance();
                  await prefs.remove('saved_hops_token');
                  const FlutterSecureStorage().delete(key: 'private_key');
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                          builder: (context) =>
                          const HopsRootGatekeeper()),
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
}