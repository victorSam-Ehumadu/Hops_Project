// lib/views/permissions_screen.dart
//
// What Hops has access to, what each thing is actually for, and exactly
// which features stop working if it's turned off.
//
// Two honest points this screen is built around:
//
//   1. An app cannot revoke its own Android permissions. There is no API
//      for it — only the system settings app can. So every "turn off"
//      here opens system settings rather than pretending to be a switch
//      that does the work itself. A toggle that silently deep-links
//      somewhere else is worse than a button that says where it's going.
//
//   2. Most permission screens describe the permission ("Location access").
//      That tells someone nothing about the decision they're making. This
//      one leads with the consequence — "the Radar goes blank, and you
//      stop receiving emergency flares" — because that is the part a
//      person can actually weigh.
//
// Hops genuinely still does a lot with permissions denied (Task Tracker,
// the assistant, reading old chats), so the framing is "here's what you
// lose", not "grant these or else".
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class _PermissionInfo {
  final Permission permission;
  final String title;
  final IconData icon;

  /// Why Hops asks. One or two sentences, plain language.
  final String why;

  /// What specifically stops working without it. These are the lines
  /// people are actually deciding on, so they name features by the names
  /// used elsewhere in the app.
  final List<String> breaks;

  /// True where turning it off means the safety features stop — worth a
  /// stronger visual warning than a convenience permission.
  final bool safetyCritical;

  const _PermissionInfo({
    required this.permission,
    required this.title,
    required this.icon,
    required this.why,
    required this.breaks,
    this.safetyCritical = false,
  });
}

const List<_PermissionInfo> _kPermissions = [
  _PermissionInfo(
    permission: Permission.bluetoothScan,
    title: "Find nearby devices",
    icon: Icons.bluetooth_searching,
    why: "Lets Hops hear other phones running Hops around you. This is how "
        "almost everything in the app works — there's no server passing your "
        "messages along, just phone to phone.",
    breaks: [
      "Radar shows nobody, ever",
      "You stop receiving emergency flares from people nearby",
      "Community Alerts receive nothing",
      "Vibe Check never sees anyone else's reports",
      "Watch Me can't tell if your buddy has moved away",
    ],
    safetyCritical: true,
  ),
  _PermissionInfo(
    permission: Permission.bluetoothAdvertise,
    title: "Be visible to nearby devices",
    icon: Icons.wifi_tethering,
    why: "Lets your phone announce itself so others can hear you. Scanning "
        "only lets you listen — this is the half that lets you speak.",
    breaks: [
      "Your emergency flare reaches nobody",
      "Admins can't send Community Alerts",
      "You don't appear on anyone else's Radar",
      "You can't send files with Hops Share",
    ],
    safetyCritical: true,
  ),
  _PermissionInfo(
    permission: Permission.bluetoothConnect,
    title: "Connect to nearby devices",
    icon: Icons.bluetooth_connected,
    why: "Needed to open a direct connection to one specific phone, rather "
        "than just broadcasting to everyone in range.",
    breaks: [
      "1:1 chats can't connect directly (they fall back to the slower mesh)",
      "Hops Share can't transfer files",
    ],
  ),
  _PermissionInfo(
    permission: Permission.location,
    title: "Location",
    icon: Icons.location_on_outlined,
    why: "Hops does not track where you are, store your location, or send it "
        "anywhere. Android simply treats scanning for nearby Bluetooth "
        "devices as something that could reveal your position, so it puts "
        "that ability behind this permission. Denying it doesn't hide your "
        "location from Hops — it stops Hops seeing other phones at all.",
    breaks: [
      "On most phones, Bluetooth scanning stops entirely",
      "Radar, Community Alerts and flare alerts go quiet with it",
    ],
    safetyCritical: true,
  ),
  _PermissionInfo(
    permission: Permission.notification,
    title: "Notifications",
    icon: Icons.notifications_active_outlined,
    why: "Lets Hops reach you when the app isn't open — which is most of the "
        "time, and all of the time that matters.",
    breaks: [
      "Emergency flares arrive silently — you'd only see them by opening the app",
      "No alerts for messages, friend requests or watch requests",
      "Admin warnings sit unread in your inbox",
    ],
    safetyCritical: true,
  ),
  _PermissionInfo(
    permission: Permission.camera,
    title: "Camera",
    icon: Icons.photo_camera_outlined,
    why: "Only used when you choose to take a profile picture or scan a "
        "pairing code. Hops never opens the camera on its own.",
    breaks: [
      "You can't scan a pairing code (you can still type it in)",
      "You can't take a new profile photo (you can still pick one)",
    ],
  ),
];

class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  Map<Permission, bool> _granted = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Changing a permission always happens in the system settings app, so
  /// coming back is the only moment the answer can have changed. Without
  /// this the screen would keep showing whatever it read when it opened.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final results = <Permission, bool>{};
    for (final info in _kPermissions) {
      try {
        results[info.permission] = await info.permission.isGranted;
      } catch (_) {
        // Not every permission exists on every platform/OS version —
        // treat an unanswerable one as not granted rather than failing the
        // whole screen.
        results[info.permission] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _granted = results;
      _loading = false;
    });
  }

  Future<void> _turnOn(_PermissionInfo info) async {
    final status = await info.permission.request();
    if (status.isPermanentlyDenied) {
      // Android stops showing the dialog after a couple of refusals; the
      // settings app is the only route left.
      await openAppSettings();
      return; // didChangeAppLifecycleState re-reads on return
    }
    await _load();
  }

  Future<void> _turnOff(_PermissionInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Turn off ${info.title.toLowerCase()}?"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("This will stop working:"),
            const SizedBox(height: 8),
            ...info.breaks.map((b) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text("•  $b", style: const TextStyle(fontSize: 13)),
                )),
            const SizedBox(height: 12),
            Text(
              // Said plainly rather than discovered by the user when the
              // next screen isn't the one they expected.
              "Apps can't switch their own permissions off, so this opens "
              "Android's settings for Hops. Turn it off there, then come back.",
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Keep it on")),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Open settings"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final missingCritical = _kPermissions
        .where((p) => p.safetyCritical && !(_granted[p.permission] ?? false))
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Permissions", style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: "Refresh"),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 20, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "You're allowed to say no to any of these. Each one "
                          "below says exactly what stops working — nothing is "
                          "hidden behind \"required for the app to function\".",
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: colors.onSurface.withValues(alpha: 0.75)),
                        ),
                      ),
                    ],
                  ),
                ),
                if (missingCritical > 0) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 20, color: Colors.orange.shade800),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            missingCritical == 1
                                ? "One safety permission is off. Emergency features may not reach you."
                                : "$missingCritical safety permissions are off. Emergency features may not reach you.",
                            style: TextStyle(
                                fontSize: 12.5,
                                height: 1.45,
                                color: colors.onSurface.withValues(alpha: 0.85)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                ..._kPermissions.map((info) => _PermissionCard(
                      info: info,
                      granted: _granted[info.permission] ?? false,
                      onTurnOn: () => _turnOn(info),
                      onTurnOff: () => _turnOff(info),
                    )),
                const SizedBox(height: 8),
                Text(
                  "Task Tracker, the Hops assistant, your saved chats and your "
                  "settings all keep working no matter what you turn off here.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: colors.onSurface.withValues(alpha: 0.45)),
                ),
              ],
            ),
    );
  }
}

class _PermissionCard extends StatefulWidget {
  final _PermissionInfo info;
  final bool granted;
  final VoidCallback onTurnOn;
  final VoidCallback onTurnOff;

  const _PermissionCard({
    required this.info,
    required this.granted,
    required this.onTurnOn,
    required this.onTurnOff,
  });

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final info = widget.info;
    final on = widget.granted;
    final warn = !on && info.safetyCritical;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: warn
            ? BorderSide(color: Colors.orange.withValues(alpha: 0.5))
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(info.icon,
                    color: on ? colors.primary : colors.onSurface.withValues(alpha: 0.4)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.title,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(
                        on ? "Allowed" : "Not allowed",
                        style: TextStyle(
                          fontSize: 12,
                          color: on ? Colors.green.shade700 : Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
                // Not a Switch. A switch promises it will do the thing when
                // flipped, and turning a permission off can only ever hand
                // you to the system settings app — so it says so.
                on
                    ? TextButton(onPressed: widget.onTurnOff, child: const Text("Turn off"))
                    : FilledButton(onPressed: widget.onTurnOn, child: const Text("Allow")),
              ],
            ),
            const SizedBox(height: 6),
            Text(info.why,
                style: TextStyle(
                    fontSize: 12.5, height: 1.45, color: colors.onSurface.withValues(alpha: 0.7))),
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(
                      _expanded ? "Hide what this affects" : "What stops working without it",
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600, color: colors.primary),
                    ),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: colors.primary),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: info.breaks
                      .map((b) => Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.remove_circle_outline,
                                    size: 13, color: colors.onSurface.withValues(alpha: 0.35)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(b,
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.4,
                                          color: colors.onSurface.withValues(alpha: 0.7))),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
