import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/views/account_management_screen.dart';
import 'package:client/views/theme_picker_screen.dart';
import 'package:client/views/terms_screen.dart';
import 'package:client/views/edit_identity_screen.dart';
import 'package:client/views/walkthrough_screen.dart';
import 'package:client/views/admin_requests_screen.dart';

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
  String _myRole = 'student';

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
      _myRole = prefs.getString('my_role') ?? 'student';
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
    final bioText = _bio.isNotEmpty ? _bio : "Your Average Hopper";

    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Profile",
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
                    ? const Icon(Icons.cruelty_free, size: 48, color: Colors.white)
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.edit, color: colors.primary),
              title: Text(
                'Edit Profile Details',
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

            // Customize button — color theme + font, merged into one
            // personalization hub rather than two separate, easy-to-miss
            // entries.
            ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.palette_outlined, color: colors.primary),
              title: Text(
                'Customize Hops',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'Color theme, font & size',
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

            // Admin approval queue — student-facing "Request Admin Access"
            // entry removed per product decision; a replacement admin
            // onboarding flow is planned separately.
            if (_myRole == 'admin')
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                leading: Icon(Icons.shield_outlined, color: colors.primary),
                title: Text(
                  'Admin Requests',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.primary),
                ),
                subtitle: Text(
                  'Review pending admin-access requests',
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
                ),
                trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const AdminRequestsScreen())),
              ),
            if (_myRole == 'admin') const SizedBox(height: 24),

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

            // Help button — was just "Help" with no subtitle, which is
            // apparently why people didn't realize tapping it replays the
            // full app walkthrough; the name alone doesn't say that.
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.help_outline, color: colors.primary),
              title: Text(
                'Help & Walkthrough',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
              ),
              subtitle: Text(
                'Replay the welcome tour of Hops\' features',
                style: TextStyle(fontSize: 12, color: colors.onBackground.withOpacity(0.7)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: colors.onBackground),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const WalkthroughScreen()),
                );
              },
            ),
            const SizedBox(height: 24),

            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.manage_accounts_outlined, color: colors.primary),
              title: Text(
                'Account Management',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.primary),
              ),
              subtitle: Text(
                'Change password, log out, or delete your account',
                style: TextStyle(fontSize: 12, color: colors.onBackground.withOpacity(0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: colors.onBackground),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AccountManagementScreen()));
              },
            ),
          ],
        ),
      ),
    );
  }
}