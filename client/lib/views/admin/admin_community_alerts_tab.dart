// lib/views/admin/admin_community_alerts_tab.dart
//
// Lets an admin compose into Community Alerts — the only side of this
// feature that can. Reuses the shared CommunityAlerts widget
// (lib/views/community_alerts.dart) as-is, same as the notification/
// verification plumbing the Listening Post already reuses from the student
// app. The only admin-specific bit is *how the message is broadcast*:
// AdminBleHub sends it tagged with this admin's own truncated username
// under the CA: (admin) prefix — see hops_constants.dart — which is what
// lets CommunityAlerts resolve and admit it on every device that receives
// it, not just this one.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/views/community_alerts.dart';

class AdminCommunityAlertsTab extends StatefulWidget {
  const AdminCommunityAlertsTab({super.key});

  @override
  State<AdminCommunityAlertsTab> createState() => _AdminCommunityAlertsTabState();
}

class _AdminCommunityAlertsTabState extends State<AdminCommunityAlertsTab> {
  String? _myUsername;

  @override
  void initState() {
    super.initState();
    _loadUsername();
    // Names in Community Alerts are resolved from this cache (see
    // community_alerts.dart's _resolveSenderAndAdd) — an admin reviewing
    // the feed needs to see who actually sent what, so make sure it's
    // current rather than relying on the Listening Post tab having been
    // opened first. Best-effort/fire-and-forget, same as everywhere else.
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
    return CommunityAlerts(
      radarStream: AdminBleHub.instance.scanStream,
      myUsername: username,
      amAdmin: true,
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
