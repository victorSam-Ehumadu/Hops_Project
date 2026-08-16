// lib/views/admin/admin_community_chat_tab.dart
//
// Lets an admin post into the same Community Chat students see, using the
// shared CommunityChat widget (lib/views/community_chat.dart) — reused
// as-is rather than duplicated, same as the notification/verification
// plumbing the Listening Post already reuses from the student app. The only
// admin-specific bit is *how the message is broadcast*: AdminBleHub sends
// it tagged with kAdminCommunityProtocolMarker (this admin's own truncated
// username, not an anonymizing rotating token — see hops_constants.dart),
// which is what makes CommunityChat resolve and style it as an admin bubble
// on every device that receives it, not just this one.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/views/community_chat.dart';

class AdminCommunityChatTab extends StatefulWidget {
  const AdminCommunityChatTab({super.key});

  @override
  State<AdminCommunityChatTab> createState() => _AdminCommunityChatTabState();
}

class _AdminCommunityChatTabState extends State<AdminCommunityChatTab> {
  String? _myUsername;

  @override
  void initState() {
    super.initState();
    _loadUsername();
    // Names in Community Chat are resolved from this cache (see
    // community_chat.dart's _resolveSenderAndAdd) — an admin reviewing
    // chat needs to see who actually said what, so make sure it's current
    // rather than relying on the Listening Post tab having been opened
    // first. Best-effort/fire-and-forget, same as everywhere else.
    KeyDirectory.sync();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _myUsername = prefs.getString('my_username'));
  }

  @override
  Widget build(BuildContext context) {
    final username = _myUsername;
    if (username == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return CommunityChat(
      radarStream: AdminBleHub.instance.scanStream,
      myUsername: username,
      amAdmin: true,
      // The whole reason an admin reads this feed is to see who said what
      // — students see anonymous labels, admins see accounts.
      showRealNames: true,
      onSendMessage: (message) async {
        // Resolved before the await, not after: looking an inherited widget
        // up off a context that may have been disposed mid-broadcast is the
        // crash this lint exists to catch.
        final messenger = ScaffoldMessenger.of(context);
        final msgId =
            await AdminBleHub.instance.broadcastAdminChatMessage(message, username);
        // Surfaced rather than swallowed — a failed broadcast still leaves
        // the message in this admin's own list, so without this it looks
        // sent when nothing left the device.
        if (msgId == null && mounted) {
          messenger.showSnackBar(const SnackBar(
            content: Text(
                "Couldn't broadcast — check Bluetooth is on and that Hops Admin has "
                "the Nearby devices permission, then try again."),
            duration: Duration(seconds: 6),
          ));
        }
        return msgId;
      },
    );
  }
}
