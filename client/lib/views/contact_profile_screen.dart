// lib/views/contact_profile_screen.dart
//
// A contact's profile card, WhatsApp-style — avatar, username, bio.
// The avatar/bio shown here are learned only by direct device-to-device
// exchange the first time you actually connect to chat with this person
// (see HopsChatService.sendProfile / chat_terminal.dart) — nothing in
// this app syncs that data through a backend, so it's genuinely absent
// until that's happened at least once.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/views/chat_terminal.dart';

class ContactProfileScreen extends StatefulWidget {
  final String peerUsername;
  final Future<void> Function(String peerUsername) onDeleteContact;

  const ContactProfileScreen({
    super.key,
    required this.peerUsername,
    required this.onDeleteContact,
  });

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen> {
  String? _avatarPath;
  String? _bio;
  bool _loading = true;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profile = await DatabaseHelper.instance.getContactProfile(widget.peerUsername);
    if (!mounted) return;
    setState(() {
      _avatarPath = profile?[DatabaseHelper.cpColAvatarPath] as String?;
      _bio = profile?[DatabaseHelper.cpColBio] as String?;
      _loading = false;
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

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete this contact?"),
        content: Text(
          "This removes ${widget.peerUsername} from your contacts and deletes your chat history with them. This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    await widget.onDeleteContact(widget.peerUsername);
    if (mounted) {
      // May have been reached via Contacts -> Profile, or Contacts ->
      // Chat -> Profile — either way the contact (and any open chat on
      // top of us) no longer makes sense to keep around, so go all the
      // way back to the tab shell rather than just popping one screen.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasBio = _bio != null && _bio!.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.peerUsername,
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            GestureDetector(
              onTap: _avatarPath != null ? _showFullImage : null,
              child: CircleAvatar(
                radius: 56,
                backgroundColor: colors.primaryContainer,
                backgroundImage: _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
                child: _avatarPath == null
                    ? const Icon(Icons.person, size: 56, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                widget.peerUsername,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: colors.primary),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              hasBio ? _bio! : "No bio shared yet — this appears once you've chatted with them.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontStyle: hasBio ? FontStyle.normal : FontStyle.italic,
                color: colors.onSurface.withOpacity(hasBio ? 0.85 : 0.5),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text("Open Chat"),
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => IndividualChatTerminalView(
                      peerName: widget.peerUsername,
                      onDeleteContact: widget.onDeleteContact,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                ),
                icon: _deleting
                    ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent))
                    : const Icon(Icons.delete_outline, size: 18),
                label: const Text("Delete Contact"),
                onPressed: _deleting ? null : _confirmDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
