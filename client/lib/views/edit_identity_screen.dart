import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class EditIdentityScreen extends StatefulWidget {
  const EditIdentityScreen({super.key});

  @override
  State<EditIdentityScreen> createState() => _EditIdentityScreenState();
}

class _EditIdentityScreenState extends State<EditIdentityScreen> {
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
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
    _avatarPath = prefs.getString('avatar_path');
    setState(() {});
  }

  Future<void> _pickAvatar() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 512,
      maxHeight: 512,
    );
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
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final nickname = _nicknameController.text.trim();
    final bio = _bioController.text.trim();

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

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _bioController.dispose();
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
              onTap: _pickAvatar,
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
              onPressed: _avatarPath != null ? _removeAvatar : _pickAvatar,
              child: Text(
                _avatarPath != null ? 'Remove photo' : 'Tap to change photo',
                style: TextStyle(color: colors.primary),   // visible
              ),
            ),
            const SizedBox(height: 24),

            // Nickname field
            TextField(
              controller: _nicknameController,
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