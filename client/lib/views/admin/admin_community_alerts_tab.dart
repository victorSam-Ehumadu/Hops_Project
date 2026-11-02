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
import 'package:client/services/hops_constants.dart';
import 'package:client/services/community_alert_sync.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/views/community_alerts.dart';
import 'package:client/utils/profanity_filter.dart';

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
      // The radio's verdict lands on an asynchronous callback the hub
      // owns, so the hub is the only thing that can say why a broadcast
      // failed. Read at display time rather than captured, so it reflects
      // the attempt that just failed.
      describeSendFailure: () => AdminBleHub.instance.lastAdvertisingError.value,
      onSendMessage: (message) async {
        // Resolved before the await, not after: looking an inherited widget
        // up off a context that may have been disposed mid-broadcast is the
        // crash this lint exists to catch.
        final messenger = ScaffoldMessenger.of(context);
        final clean = censorProfanity(message);
        final msgId =
            await AdminBleHub.instance.broadcastAdminChatMessage(clean, username);

        // Also publish to the server, so a student whose Bluetooth was off
        // — or who has never been online, and therefore has an empty
        // KeyDirectory and silently drops CA: chunks — still gets this on
        // their next poll. See community_alert_sync.dart for why this one
        // feature has a server path when no other peer feature does.
        //
        // Awaited but not checked: the BLE send above is the primary
        // result and the thing the admin is told about. An alert that went
        // out over the radio reached everyone in range whether or not this
        // succeeded, and a failure here only costs the catch-up path.
        //
        // The BLE msgId and sender tag go with it so a device that hears
        // the alert over the radio AND later fetches it from the server
        // recognises the two as one message rather than showing it twice.
        await CommunityAlertSync.instance.post(
          body: clean,
          senderTag: username.length > kCommunityNameSenderTagChars
              ? username.substring(0, kCommunityNameSenderTagChars)
              : username,
          msgId: msgId,
        );
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
