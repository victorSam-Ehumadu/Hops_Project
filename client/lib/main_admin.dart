// lib/main_admin.dart
//
// Entry point for the separate Admin app — a second flavor of this same
// codebase (see CLAUDE.md's Architecture section) rather than an
// independent project, so it can reuse identity/crypto/BLE primitives
// (mesh_crypto.dart, the ble_peripheral/flutter_blue_plus advertise+scan
// helpers) instead of re-implementing them. Run with:
//   flutter run -t lib/main_admin.dart
//
// Deliberately much thinner than main.dart: no sqflite (nothing here reads
// messages/vibe_records/tasks — those stay device-local to whoever sent
// them, see 0008_admin_moderation.sql's header comment), no quick_actions
// shortcuts, no walkthrough/terms/onboarding.
//
// It DOES run the same flutter_foreground_task + NotificationService setup
// as main.dart, for the same reason: the Listening Post tab's BLE scan
// (admin_alert_tab.dart) is normal main-isolate Dart code, same as the
// student app's continuous scan — Android throttles/kills that once the
// app is backgrounded or the screen is off unless the process holds a
// foreground-service exemption. AndroidManifest.xml's foreground-service
// permissions/declaration are shared across every Dart entry point in this
// app (there's only one manifest/APK — see this file's own header note
// about no distinct admin app icon/build flavor yet), so nothing native
// needed changing to enable this here.
//
// Admin accounts are provisioned out-of-band (see profiles.role in
// 0008_admin_moderation.sql) and this app never signs one up — only in.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/account_standing.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/views/admin/admin_sign_in_screen.dart';
import 'package:client/views/admin/admin_shell.dart';
import 'package:client/views/hops_splash_screen.dart';
import 'package:client/widgets/alarm_ringing_banner.dart';
// themeNotifier/fontScaleNotifier are declared in main.dart. Importing the
// student entry point from the admin one only pulls in those globals — no
// student UI is reachable from here, and keeping one source of truth for
// the saved theme means both apps agree on what's stored.
import 'package:client/main.dart' show themeNotifier, fontScaleNotifier;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Same portrait lock as the student app (main.dart) — every screen here
  // is built the same fixed-width-card way and no more adapts to
  // landscape than the student app's does.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Needed before the Listening Post can raise its alarm-style alert
  // (NotificationService.showEmergencyNotification/
  // showOfficialAlertNotification — the exact same full-screen-intent,
  // looping-siren notification the student app uses for EMG:/ADM:, reused
  // as-is rather than duplicated) even with the screen off.
  await NotificationService.init();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      // Deliberately a different channelId than main.dart's
      // 'foreground_service' — Android notification channels are
      // immutable once created (first call wins on name/description), and
      // until this app has its own build flavor (see this file's header
      // comment) it shares one manifest/package with the student app, so
      // reusing that id risks this channel silently keeping whichever
      // app's name/description got created first on a device that's run
      // both.
      channelId: 'admin_foreground_service',
      channelName: 'Hops Admin Service',
      channelDescription: 'Keeps the Listening Post scanning for flares and alerts',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: const ForegroundTaskOptions(
      autoRunOnBoot: true,
      allowWakeLock: true,
    ),
  );

  await FlutterForegroundTask.startService(
    notificationTitle: 'Hops Admin is active',
    notificationText: 'Listening Post is scanning for flares and alerts…',
  );

  await dotenv.load(fileName: ".env");
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  // Restore the saved appearance before the first frame, or the admin app
  // starts on the default light theme every launch and only jumps to the
  // chosen one once Settings is opened.
  final prefs = await SharedPreferences.getInstance();
  themeNotifier.value = prefs.getInt('selected_theme_index') ?? 0;
  fontScaleNotifier.value = prefs.getDouble('font_scale') ?? 1.0;

  // Load the stored moderation verdict before the first frame, so the
  // launch gate below reads a populated value rather than the default.
  await AccountStandingStore.instance.load();

  runApp(const HopsAdminRoot());
}

class HopsAdminRoot extends StatefulWidget {
  const HopsAdminRoot({super.key});

  @override
  State<HopsAdminRoot> createState() => _HopsAdminRootState();
}

class _HopsAdminRootState extends State<HopsAdminRoot> {
  // The theme was previously hard-wired to AppThemes.all.first on the
  // grounds that themes were a student-only cosmetic preference. Admin
  // Settings' dark-mode switch changed that: a night shift staring at a
  // white dashboard is a real complaint, so this now listens to the same
  // notifiers the student app does. Font *pairing* is still left out —
  // that one really is decoration.
  late int _themeIndex;
  late double _fontScale;

  // Cold start only — this widget is built once for the process lifetime.
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    _themeIndex = themeNotifier.value;
    _fontScale = fontScaleNotifier.value;
    themeNotifier.addListener(_onThemeChanged);
    fontScaleNotifier.addListener(_onFontScaleChanged);
  }

  @override
  void dispose() {
    themeNotifier.removeListener(_onThemeChanged);
    fontScaleNotifier.removeListener(_onFontScaleChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (_themeIndex != themeNotifier.value) {
      setState(() => _themeIndex = themeNotifier.value);
    }
  }

  void _onFontScaleChanged() {
    if (_fontScale != fontScaleNotifier.value) {
      setState(() => _fontScale = fontScaleNotifier.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Guarded: a stored index from a build with a different-length catalog
    // would throw here, at the very top of the tree, taking the app with it.
    final safeIndex =
        (_themeIndex >= 0 && _themeIndex < AppThemes.all.length) ? _themeIndex : 0;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppThemes.all[safeIndex].toThemeData(),
      home: _splashDone
          // Swapped in place rather than pushed, so the splash can't
          // navigate anywhere itself and the signed-in/signed-out decision
          // in _AdminEntryGate still runs. See main.dart for the same
          // reasoning on the student side.
          ? const _AdminEntryGate()
          : HopsSplashScreen(
              variant: HopsSplashVariant.admin,
              onFinished: () {
                if (mounted) setState(() => _splashDone = true);
              },
            ),
      // Same alarm banner as the student app (main.dart), and for the same
      // reason: an admin device rings on its own detected flares/alerts
      // too (see AdminBleHub._scanForAlerts), and this needs to stay
      // reachable over whatever screen the admin happens to be looking at,
      // not just the Dashboard.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(_fontScale.clamp(0.85, 1.6))),
        child: Column(
          children: [
            const AlarmRingingBanner(),
            Expanded(child: child!),
          ],
        ),
      ),
    );
  }
}

// Mirrors HopsRoot._getHomeWidget's shape (main.dart) — a saved token means
// skip straight past sign-in. Unlike the student app, also re-checks the
// *locally cached* role before doing that: a demoted/banned admin's stale
// token shouldn't reopen the admin shell just because it's still saved.
// This is only a first line of defense for UX (skip a flash of the admin
// shell before bouncing back out) — AdminShell's own periodic status poll
// (mirroring hops_app.dart's _syncIdentityStatus) is what actually enforces
// it against the server on every subsequent check.
class _AdminEntryGate extends StatelessWidget {
  const _AdminEntryGate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final prefs = snapshot.data!;
        final token = prefs.getString('saved_hops_token');
        final role = prefs.getString('my_role');
        // A stored moderation verdict keeps a banned or suspended admin
        // out at launch, exactly as it does in the student app — without
        // this, force-closing and reopening restored full moderation
        // powers until a poll next happened to succeed. Read from local
        // storage, so it holds with no connection.
        final blocked = AccountStandingStore.instance.current.value.blocksUse;
        if (token != null && role == 'admin' && !blocked) {
          return const AdminShell();
        }
        return const AdminSignInScreen();
      },
    );
  }
}
