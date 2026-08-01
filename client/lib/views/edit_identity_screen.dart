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

    // Read bytes and save to permanent storage
    final Uint8List imageBytes = await image.readAsBytes();
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final savedImage = File('${dir.path}/$fileName');
    await savedImage.writeAsBytes(imageBytes);

    setState(() => _avatarPath = savedImage.path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatar_path', savedImage.path);
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
        title: const Text('Edit Identity'),
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
                backgroundImage:
                _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
                child: _avatarPath == null
                    ? const Icon(Icons.camera_alt, size: 48, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _removeAvatar,
              child: const Text('Remove photo'),
            ),
            const SizedBox(height: 24),

            // Nickname field
            TextField(
              controller: _nicknameController,
              decoration: InputDecoration(
                labelText: 'Nickname',
                hintText: 'Your display name',
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
              decoration: InputDecoration(
                labelText: 'Bio',
                hintText: 'Tell people about yourself',
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