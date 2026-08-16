import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/views/account_management_screen.dart';
import 'package:client/views/theme_picker_screen.dart';
import 'package:client/views/permissions_screen.dart';
import 'package:client/views/terms_screen.dart';
import 'package:client/views/edit_identity_screen.dart';
import 'package:client/views/walkthrough_screen.dart';

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
  String? _myAdminTitle;

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
      _myAdminTitle = prefs.getString('my_admin_title');
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
            // Admin privilege is granted out-of-band now (a provisioned
            // device, see 0008_admin_moderation.sql) rather than requested
            // from inside the app — this badge is the only place the
            // student app still surfaces role at all, so it's worth
            // keeping visible rather than silent.
            if (_myRole == 'admin') ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield, size: 12, color: colors.primary),
                    const SizedBox(width: 4),
                    Text(
                      _myAdminTitle?.isNotEmpty == true ? _myAdminTitle! : 'Admin',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: colors.primary),
                    ),
                  ],
                ),
              ),
            ],
            Text(
              bioText,
              style: TextStyle(
                  fontSize: 14,
                  color: colors.onSurface.withValues(alpha: 0.6)),
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
                  color: colors.onSurface),
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
                    color: colors.onSurface.withValues(alpha: 0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18,
                  color: colors.onSurface),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ThemePickerScreen()));
              },
            ),
            const SizedBox(height: 24),

            // Permissions — deliberately its own entry rather than buried
            // in Customize. What Hops can access, and what breaks if you
            // switch any of it off, is a different kind of decision from
            // picking a colour theme, and people go looking for it by name.
            ListTile(
              contentPadding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              leading: Icon(Icons.lock_outline, color: colors.primary),
              title: Text(
                'Permissions',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: colors.primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'What Hops can access, and what turning it off costs',
                style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurface.withValues(alpha: 0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18,
                  color: colors.onSurface),
              onTap: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const PermissionsScreen()));
              },
            ),
            const SizedBox(height: 24),

            // Admin privilege is granted out-of-band now (a provisioned
            // device, not a request/approval flow from inside the app —
            // see supabase/migrations/0008_admin_moderation.sql), so
            // there's no student-app entry point for it at all anymore;
            // admin-only screens live in the separate Admin app instead.

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
                  color: colors.onSurface),
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
                style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface),
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
                style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface),
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