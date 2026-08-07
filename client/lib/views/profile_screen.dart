import 'dart:io';
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
import 'package:client/views/edit_identity_screen.dart';

class HopsProfileScreen extends StatefulWidget {
  const HopsProfileScreen({super.key});
  @override
  State<HopsProfileScreen> createState() => _HopsProfileScreenState();
}

class _HopsProfileScreenState extends State<HopsProfileScreen> {
  String dynamicProfileUsername = "Loading Node...";
  String _nickname = '';
  String _bio = '';
  String? _avatarPath;

  @override
  void initState() {
    super.initState();
    _loadPersistedIdentityStrings();
    _loadIdentityData();
  }

  Future<void> _loadPersistedIdentityStrings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      dynamicProfileUsername =
          prefs.getString('my_username') ?? 'Mesh_Operator';
    });
  }

  Future<void> _loadIdentityData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _nickname = prefs.getString('nickname') ?? '';
      _bio = prefs.getString('bio') ?? '';
      _avatarPath = prefs.getString('avatar_path');
    });
  }

  void _showFullImage() {
    if (_avatarPath == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: InteractiveViewer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.file(File(_avatarPath!)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final displayName =
    _nickname.isNotEmpty ? _nickname : dynamicProfileUsername;
    final bioText = _bio.isNotEmpty ? _bio : "Average Hopper";

    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Profile Identity",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colors.primary),
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
            GestureDetector(
              onTap: _showFullImage,
              child: CircleAvatar(
                radius: 48,
                backgroundColor: colors.primaryContainer,
                backgroundImage: _avatarPath != null
                    ? FileImage(File(_avatarPath!))
                    : null,
                child: _avatarPath == null
                    ? const Icon(Icons.person, size: 48, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                displayName,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: colors.primary),
              ),
            ),
            Text(
              bioText,
              style: TextStyle(
                  fontSize: 14,
                  color: colors.onBackground.withOpacity(0.6)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 32),

            // Edit Identity button
            ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.edit, color: colors.primary),
              title: Text(
                'Edit Identity',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
              ),
              trailing: Icon(Icons.chevron_right, size: 18,
                  color: colors.onBackground),
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const EditIdentityScreen()),
                );
                if (result == true) {
                  _loadIdentityData();
                  setState(() {});
                }
              },
            ),

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
              leading:
              Icon(Icons.description_outlined, color: colors.primary),
              title: Text(
                'Terms and Conditions',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
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
                leading:
                const Icon(Icons.logout, color: Colors.redAccent),
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