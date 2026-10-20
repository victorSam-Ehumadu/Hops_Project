import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:client/services/avatar_path_notifier.dart';
import 'package:client/utils/profanity_filter.dart';

class EditIdentityScreen extends StatefulWidget {
  const EditIdentityScreen({super.key});

  @override
  State<EditIdentityScreen> createState() => _EditIdentityScreenState();
}

class _EditIdentityScreenState extends State<EditIdentityScreen> {
  // Character limits — nothing here used to be bounded at all, so a
  // nickname or bio of any length would happily get typed in (and, for
  // nickname especially, break layouts elsewhere that assumed something
  // short — the app bar, contact tiles, the profile header).
  static const int _kNicknameMaxLength = 24;
  static const int _kBioMaxLength = 140;
  static const int _kThinkingMaxLength = 60;

  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  // "What are you thinking?" — shown as a thought-bubble next to your
  // avatar on your own Profile screen and, once a contact profile syncs
  // (see hops_chat_service.dart's sendProfile), on theirs when they view
  // you in Contacts. Deliberately short — a running commentary field, not
  // a second bio.
  final TextEditingController _thinkingController = TextEditingController();
  String? _avatarPath;

  @override
  void initState() {
    super.initState();
    _loadCurrentData();
  }

  Future<void> _loadCurrentData() async {
    final prefs = await SharedPreferences.getInstance();
    _nicknameController.text = prefs.getString('nickname') ?? '';
    _bioController.text = prefs.getString('bio') ?? '';
    _thinkingController.text = prefs.getString('thinking_status') ?? '';
    _avatarPath = prefs.getString('avatar_path');
    setState(() {});
  }

  /// Asks whether to use the camera or the gallery, then picks.
  ///
  /// The avatar is the ONE place in Hops that opens a camera — the profile
  /// banner and everything else are gallery-only. Taking a photo in the
  /// moment is worth a camera path; nothing else here is.
  Future<void> _chooseAvatarSource() async {
    final colors = Theme.of(context).colorScheme;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: colors.primary),
              title: Text('Take a photo',
                  style: TextStyle(
                      color: colors.onSurface, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: colors.primary),
              title: Text('Choose from gallery',
                  style: TextStyle(
                      color: colors.onSurface, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return; // dismissed
    await _pickAvatar(source);
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image;
    try {
      image = await picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 512,
        maxHeight: 512,
      );
    } catch (e) {
      // A handset with no camera app, or one that refuses the capture
      // intent, throws here rather than returning null. Say so instead of
      // appearing to do nothing — the gallery is still available.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(source == ImageSource.camera
              ? "Couldn't open the camera — you can still pick a photo from your gallery."
              : "Couldn't open the gallery."),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    if (image == null) return;

    // Each pick used to write a new timestamped file and just abandon the
    // previous one — avatars accumulated on disk forever. Delete the old
    // one (if any) before saving the new one's path.
    final previousPath = _avatarPath;

    final Uint8List imageBytes = await image.readAsBytes();
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final savedImage = File('${dir.path}/$fileName');
    await savedImage.writeAsBytes(imageBytes);

    setState(() => _avatarPath = savedImage.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatar_path', savedImage.path);
    avatarPathRevision.value++;

    if (previousPath != null && previousPath != savedImage.path) {
      final oldFile = File(previousPath);
      if (await oldFile.exists()) {
        try {
          await oldFile.delete();
        } catch (_) {
          // Best-effort cleanup — not worth surfacing an error for this.
        }
      }
    }
  }

  Future<void> _removeAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('avatar_path');
    if (_avatarPath != null) {
      final file = File(_avatarPath!);
      if (await file.exists()) await file.delete();
    }
    setState(() => _avatarPath = null);
    avatarPathRevision.value++;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    // Censored before saving, not just before display — bio/thinking sync
    // to contacts (see hops_chat_service.dart's sendProfile), so the
    // stored value is what actually reaches someone else's screen; a
    // display-only filter would leave the raw, uncensored text sitting in
    // the payload another device receives and could render its own way.
    final nickname = censorProfanity(_nicknameController.text.trim());
    final bio = censorProfanity(_bioController.text.trim());
    final thinking = censorProfanity(_thinkingController.text.trim());

    if (nickname.isNotEmpty) {
      await prefs.setString('nickname', nickname);
    } else {
      await prefs.remove('nickname');
    }
    if (bio.isNotEmpty) {
      await prefs.setString('bio', bio);
    } else {
      await prefs.remove('bio');
    }
    if (thinking.isNotEmpty) {
      await prefs.setString('thinking_status', thinking);
    } else {
      await prefs.remove('thinking_status');
    }

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _bioController.dispose();
    _thinkingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Edit Identity',
          style: TextStyle(color: colors.primary),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Avatar section
            GestureDetector(
              onTap: _chooseAvatarSource,
              child: CircleAvatar(
                radius: 48,
                backgroundColor: colors.primaryContainer,
                backgroundImage: _avatarPath != null
                    ? FileImage(File(_avatarPath!))
                    : null,
                child: _avatarPath == null
                    ? const Icon(Icons.camera_alt, size: 48, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              // No photo yet → tapping here does the same thing as tapping
              // the avatar itself. Once one's set, this becomes the way to
              // clear it — showing "Remove photo" when there's nothing to
              // remove was confusing (and did nothing when tapped).
              onPressed:
                  _avatarPath != null ? _removeAvatar : _chooseAvatarSource,
              child: Text(
                _avatarPath != null ? 'Remove photo' : 'Tap to add a photo',
                style: TextStyle(color: colors.primary),   // visible
              ),
            ),
            const SizedBox(height: 24),

            // Nickname field
            TextField(
              controller: _nicknameController,
              maxLength: _kNicknameMaxLength,
              style: TextStyle(color: colors.onSurface),   // typed text
              decoration: InputDecoration(
                labelText: 'Nickname',
                labelStyle: TextStyle(color: colors.primary.withValues(alpha: 0.7)),
                hintText: 'Your display name',
                hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.4)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Bio field
            TextField(
              controller: _bioController,
              maxLines: 3,
              maxLength: _kBioMaxLength,
              style: TextStyle(color: colors.onSurface),   // typed text
              decoration: InputDecoration(
                labelText: 'Bio',
                labelStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.7)),
                hintText: 'Tell people about yourself',
                hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.4)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // "Thinking" field — a short thought-bubble status shown next
            // to the avatar on Profile (yours) and Contact Profile (a
            // contact's, once it's synced to them — see
            // hops_chat_service.dart's sendProfile).
            TextField(
              controller: _thinkingController,
              maxLength: _kThinkingMaxLength,
              style: TextStyle(color: colors.onSurface),   // typed text
              decoration: InputDecoration(
                labelText: "What are you thinking?",
                labelStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.7)),
                hintText: 'Shown as a thought bubble on your profile',
                hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.4)),
                prefixIcon: Icon(Icons.chat_bubble_outline, color: colors.primary),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colors.primary, width: 2),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}