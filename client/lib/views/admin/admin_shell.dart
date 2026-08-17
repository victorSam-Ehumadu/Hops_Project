// lib/views/admin/admin_shell.dart
//
// Admin app's tabbed home — mirrors hops_app.dart's role (tab shell +
// periodic identity-sync poll) but for a much smaller, admin-only surface:
// Dashboard replaces Radar as the default tab (see the brainstorm this was
// designed from — a provisioned device doesn't need to discover nearby
// students, it needs a moderation/ops overview), and there's no Contacts/
// Community/Features tab at all.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/views/admin/admin_sign_in_screen.dart';
import 'package:client/views/admin/admin_dashboard_tab.dart';
import 'package:client/views/admin/admin_moderation_tab.dart';
import 'package:client/views/admin/admin_users_tab.dart';
import 'package:client/views/admin/admin_action_log_tab.dart';
import 'package:client/views/admin/admin_community_alerts_tab.dart';
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/main.dart' show navBarPillHeightNotifier;

/// Clears the locally-cached admin session and drops the caller back onto
/// sign-in. Mirrors account_management_screen.dart's
/// wipeLocalIdentityAndReturnToGatekeeper, but that one hard-codes
/// HopsRootGatekeeper as the destination — wrong app entirely here, so this
/// stays a separate, admin-app-local function rather than trying to
/// parametrize the shared one for a destination it was never meant to have.
Future<void> signOutOfAdminApp(BuildContext context, {String? reason}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_hops_token');
  await prefs.remove('my_hops_id');
  await prefs.remove('my_username');
  await prefs.remove('my_email');
  await prefs.remove('my_role');
  await prefs.remove('my_admin_title');
  await const FlutterSecureStorage().delete(key: 'private_key');

  if (context.mounted) {
    if (reason != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(reason), duration: const Duration(seconds: 5)),
      );
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AdminSignInScreen()),
      (route) => false,
    );
  }
}

class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _currentIndex = 0;
  Timer? _identitySyncTimer;

  @override
  void initState() {
    super.initState();
    // One-time BlePeripheral.initialize() + the shared continuous scan both
    // the Listening Post and Admin Community Alerts subscribe to — see
    // admin_ble_hub.dart's header comment. AdminShell is only ever reached
    // after sign-in (or a cached session) already requested Bluetooth
    // permissions (admin_sign_in_screen.dart), so it's safe to start here.
    _ensurePermissionsThenStartBle();
    // Same pull-based pattern as hops_app.dart's _syncIdentityStatus (no
    // push infra — see that file's comment) — catches a demote/ban that
    // happens while this device is already signed in and mid-shift. Shortened
    // from 3 minutes to match hops_app.dart's own fix for the same latency —
    // see that file's _identitySyncTimer comment.
    _identitySyncTimer = Timer.periodic(const Duration(seconds: 30), (_) => _syncIdentityStatus());
    _syncIdentityStatus();
  }

  @override
  void dispose() {
    _identitySyncTimer?.cancel();
    super.dispose();
  }

  // A restored session (cached token + role, see main_admin.dart's
  // _AdminEntryGate) lands straight here without ever passing through the
  // sign-in screen, which is the only other place that asks for these. On
  // Android 12+ BLUETOOTH_ADVERTISE/SCAN are runtime permissions, so
  // without this the Listening Post and Official Alert/Community Alerts
  // broadcasting could all silently do nothing on such a session.
  // Re-requesting an already-granted permission is a no-op.
  Future<void> _ensurePermissionsThenStartBle() async {
    try {
      await [
        Permission.location,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.bluetoothScan,
      ].request();
    } catch (_) {
      // Fall through and try to start anyway — the failure surfaces at the
      // point of use (see broadcastAdminChatMessage's return value).
    }
    await AdminBleHub.instance.ensureStarted();
  }

  Future<void> _syncIdentityStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) return;
    try {
      final response = await Supabase.instance.client
          .rpc('get_my_status', params: {'p_hops_token': token}).maybeSingle();
      if (response == null) {
        // Token expired/invalid server-side (e.g. demote_admin force-expires
        // it — see 0008_admin_moderation.sql) — same outcome as an
        // explicit demotion below.
        if (mounted) {
          await signOutOfAdminApp(context,
              reason: "Your session ended — sign in again to continue.");
        }
        return;
      }
      if (response['role'] != 'admin' && mounted) {
        await signOutOfAdminApp(context,
            reason: "Admin access for this account was removed.");
      }
    } on PostgrestException catch (e) {
      if (e.message.contains('account_banned') && mounted) {
        await signOutOfAdminApp(context,
            reason: "This account has been suspended.");
      }
      // Any other error: offline/unreachable, try again next cycle.
    } catch (_) {
      // Offline/unreachable — try again next cycle.
    }
  }

  // Five, down from six. Official Alert lost its seat: broadcasting a
  // campus-wide siren is rare and deliberate, so it doesn't need a
  // permanent slot next to the tabs used every shift — it's now a button on
  // the Dashboard, behind a confirmation. Settings sits in the Dashboard's
  // app bar for the same reason.
  static const _tabs = [
    AdminDashboardTab(),
    AdminModerationTab(),
    AdminUsersTab(),
    AdminCommunityAlertsTab(), // reads AdminBleHub.instance internally, not via constructor — stays const-constructible
    AdminActionLogTab(),
  ];

  // Community Alerts' compose bar reserves bottom clearance for itself
  // using navBarPillHeightNotifier (see main.dart). That exists for the
  // STUDENT app, whose Scaffold sets extendBody: true so the floating nav
  // pill hovers over the body — there, the body genuinely does have to keep
  // the pill's height clear or the pill covers the text field.
  //
  // This Scaffold does not set extendBody. An ordinary bottomNavigationBar
  // means the body is already laid out to stop above the NavigationBar, so
  // reporting that bar's height here made Community Alerts reserve it a
  // second time: one whole nav bar of dead space between the input and the
  // tabs, which is exactly what it looked like.
  //
  // Zero is the honest answer to the question the notifier actually asks —
  // "how much must the body clear by itself?" — and it's a constant rather
  // than a measurement because it can't vary while this Scaffold stays
  // extendBody-free.
  void _resetNavClearance() {
    if (navBarPillHeightNotifier.value != 0) {
      navBarPillHeightNotifier.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    _resetNavClearance();
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        backgroundColor: colors.surface,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: "Dashboard"),
          NavigationDestination(icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: "Reports"),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: "Users"),
          NavigationDestination(icon: Icon(Icons.campaign_outlined), selectedIcon: Icon(Icons.campaign), label: "Alerts"),
          NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history), label: "Log"),
        ],
      ),
    );
  }
}
