import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/views/account_management_screen.dart';
import 'package:client/views/theme_picker_screen.dart';
import 'package:client/views/permissions_screen.dart';
import 'package:client/views/terms_screen.dart';
import 'package:client/views/edit_identity_screen.dart';
import 'package:client/views/character_creator_page.dart';
import 'package:client/views/accessibility_settings_page.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/avatar_frames.dart';
import 'package:client/theme/username_flairs.dart';
import 'package:client/theme/profile_banners.dart';
import 'package:client/views/help_screen.dart';
import 'package:client/services/avatar_path_notifier.dart';
import 'package:client/widgets/thought_bubble.dart';

class HopsProfileScreen extends StatefulWidget {
  const HopsProfileScreen({super.key});
  @override
  State<HopsProfileScreen> createState() => _HopsProfileScreenState();
}

class _HopsProfileScreenState extends State<HopsProfileScreen> {
  static const double _bannerHeight = 120;
  static const double _avatarDiameter = 96;

  String dynamicProfileUsername = "Loading Node...";
  String _nickname = '';
  String _bio = '';
  String _thinking = '';
  String? _avatarPath;
  String? _customBannerPath;
  String _myRole = 'student';
  String? _myAdminTitle;

  @override
  void initState() {
    super.initState();
    _loadPersistedIdentityStrings();
    _loadIdentityData();
    CosmeticPrefs.instance.load();
    avatarPathRevision.addListener(_loadIdentityData);
  }

  @override
  void dispose() {
    avatarPathRevision.removeListener(_loadIdentityData);
    super.dispose();
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
      _thinking = prefs.getString('thinking_status') ?? '';
      _avatarPath = prefs.getString('avatar_path');
      _customBannerPath = prefs.getString(kCustomBannerPathKey);
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
      body: Column(
        children: [
          // Discord-style header: a full-bleed banner with the avatar
          // overlapping its bottom edge (rather than sitting fully below
          // it) — centered, not pinned to the left the way Discord's own
          // layout is, to match how the rest of this screen is already
          // centered. The online-status dot and thought bubble both live
          // in this same Stack so they can be positioned relative to the
          // avatar regardless of banner height.
          SizedBox(
            height: _bannerHeight + _avatarDiameter / 2,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: CosmeticPrefs.instance.profileBanner,
                  builder: (context, bannerId, _) {
                    final showCustom = bannerId == kBannerCustom && _customBannerPath != null;
                    return SizedBox(
                      height: _bannerHeight,
                      width: double.infinity,
                      child: showCustom
                          ? Image.file(File(_customBannerPath!), fit: BoxFit.cover)
                          : BannerPreview(
                        option: BannerOptions.byId(bannerId == kBannerCustom ? kBannerDefault : bannerId),
                        height: _bannerHeight,
                        borderRadius: BorderRadius.zero,
                      ),
                    );
                  },
                ),
                // Avatar + online dot, centered horizontally, vertically
                // centered ON the banner's bottom edge so half of it
                // overlaps the banner and half sits below it.
                Positioned(
                  top: _bannerHeight - _avatarDiameter / 2,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ValueListenableBuilder<String>(
                      valueListenable: CosmeticPrefs.instance.avatarFrame,
                      builder: (context, frameId, _) => GestureDetector(
                        onTap: _showFullImage,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            HopsAvatarFrame(
                              frameId: frameId,
                              avatarDiameter: _avatarDiameter,
                              child: CircleAvatar(
                                radius: _avatarDiameter / 2,
                                backgroundColor: colors.primaryContainer,
                                backgroundImage: _avatarPath != null
                                    ? FileImage(File(_avatarPath!))
                                    : null,
                                child: _avatarPath == null
                                    ? const Icon(Icons.cruelty_free, size: _avatarDiameter / 2, color: Colors.white)
                                    : null,
                              ),
                            ),
                            // Online-status dot — this device is, by
                            // definition, always the one currently
                            // viewing its own profile, so this is always
                            // "on" here (a contact's Contact Profile
                            // screen is a separate widget that doesn't
                            // have this certainty).
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: theme.scaffoldBackgroundColor, width: 3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // Thought bubble — "what are you thinking" (see
                // edit_identity_screen.dart), floating just above/right of
                // the avatar. Only shown once something's actually set;
                // an empty bubble would just be visual noise.
                if (_thinking.isNotEmpty)
                  Positioned(
                    top: _bannerHeight - _avatarDiameter / 2 - 28,
                    left: MediaQuery.of(context).size.width / 2 + _avatarDiameter / 2 - 12,
                    child: ThoughtBubble(text: _thinking),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: colors.primary),
                        ),
                        ValueListenableBuilder<String>(
                          valueListenable: CosmeticPrefs.instance.flair,
                          builder: (context, flairId, _) {
                            final emoji = FlairOptions.byId(flairId).emoji;
                            if (emoji == null) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(emoji, style: const TextStyle(fontSize: 20)),
                            );
                          },
                        ),
                      ],
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

                  // Character Avatar — build-your-own creature avatar (Shop-
                  // gated parts), separate from the plain photo upload above
                  // since it's a whole build-then-apply flow of its own.
                  ListTile(
                    contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    leading: Icon(Icons.face_retouching_natural, color: colors.primary),
                    title: Text(
                      'Character Avatar',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: colors.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Build a custom creature avatar with carrots',
                      style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurface.withValues(alpha: 0.7)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(Icons.chevron_right, size: 18,
                        color: colors.onSurface),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CharacterCreatorPage()),
                      ).then((_) {
                        _loadIdentityData();
                        setState(() {});
                      });
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

                  ListTile(
                    contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    leading: Icon(Icons.accessibility_new, color: colors.primary),
                    title: Text(
                      'Accessibility',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: colors.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Text size, read-aloud messages, colorblind-friendly signals',
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
                              builder: (_) => const AccessibilitySettingsPage()));
                    },
                  ),
                  const SizedBox(height: 24),

                  // Hops Shop moved out of Settings — it's now a persistent
                  // button on the Features tab (hops_app.dart's
                  // _buildShopButton), which is a more natural home for it than
                  // being buried a level deep here, and one entry point is
                  // simpler to keep straight than two.

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

                  // Help and Walkthrough — one entry point (see help_screen.dart's
                  // header comment for why this was merged back from two rows).
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
                      'FAQs, the welcome tour, and how to contact Hops directly',
                      style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.7)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const HelpScreen()),
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
          ),
        ],
      ),
    );
  }
}