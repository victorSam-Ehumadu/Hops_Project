import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/views/hops_app.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/foreground_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

final ValueNotifier<int> themeNotifier = ValueNotifier<int>(0);
// -1 means "no font chosen yet" — keeps the pre-existing system-default
// look until someone actually picks one in the new Customize screen,
// rather than forcing a font pairing on every existing install.
final ValueNotifier<int> fontNotifier = ValueNotifier<int>(-1);

// In-app text-size control, independent of the device's own system-wide
// accessibility text scale — see font_size_page.dart. Deliberately
// replaces (rather than multiplies with) the system scale in the
// MediaQuery override below: stacking an in-app multiplier on top of
// whatever the system is already applying could push tight layouts (radar
// labels, the nav pill, chat bubbles) well past what the existing clamp
// was ever tuned to tolerate. This way "font size" in Hops always means
// exactly what the slider says, on every device.
final ValueNotifier<double> fontScaleNotifier = ValueNotifier<double>(1.0);

// Set once by QuickActions' handler (see main() below) whenever a
// home-screen app-icon shortcut is tapped — HopsApp listens for this and
// clears it back to null once handled, so it behaves as a one-shot signal
// rather than a persistent "current shortcut" value. Covers both cold
// start (app wasn't running — HopsApp reads the value once at init) and
// warm start (app already running — the listener fires immediately).
final ValueNotifier<String?> shortcutNotifier = ValueNotifier<String?>(null);

// Counts how many nearby_connections-based sessions (1:1 Chat,
// Hops Share) are currently open anywhere in the app — a plain int rather
// than a bool so two such screens open at once (or one opening while
// another is still tearing down) don't clobber each other. HopsApp's own
// background BLE peripheral advertising and its periodic "recheck ambient
// device count" scan cycle compete with nearby_connections for the same
// Bluetooth radio (see hops_chat_service.dart's header comment) — every
// screen that starts a nearby_connections session increments this in
// initState and decrements it in dispose, and HopsApp pauses the two
// worst-offending timers for as long as it's above zero, regardless of how
// deep in the navigation stack that screen is (a global notifier avoids
// having to plumb a callback through every intermediate screen, e.g.
// ContactProfileScreen → IndividualChatTerminalView).
final ValueNotifier<int> nearbyConnectionsSessionCount = ValueNotifier<int>(0);

// One-shot signal (same shape as shortcutNotifier above): a chat screen
// sets this to the peer's username to ask HopsApp to broadcast a short
// "come open our chat" BLE ping (see hops_app.dart's CHT: advertisement) —
// the only channel that can reach a peer who isn't currently running a
// matching nearby_connections session themselves. HopsApp resets it back
// to null once the ping's gone out.
final ValueNotifier<String?> chatPingRequest = ValueNotifier<String?>(null);

// Real, measured height (in logical pixels) of HopsApp's floating nav
// pill — arrow handle + gap + the pill itself — refreshed every frame it's
// visible (see hops_app.dart's _buildFloatingNavBar). Exists so a screen
// that has to position its own content just above the pill by hand (e.g.
// Community Chat's message input) can clear it exactly, instead of
// guessing a fixed offset from kFloatingNavClearance (hops_constants.dart)
// — that constant is deliberately oversized "don't get covered" padding
// for scrollable lists where a little extra empty space at the bottom is
// invisible, which is why hand-tuning it for a single fixed-height bar
// kept coming back as "still too high" even after being adjusted twice.
final ValueNotifier<double> navBarPillHeightNotifier = ValueNotifier<double>(96);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hops' whole UI (radar canvas, floating nav pill, fixed-width cards) is
  // built and hand-tuned for portrait only — nothing about it adapts to a
  // landscape layout, so rather than let it render broken sideways, lock
  // orientation regardless of the device's rotation lock setting.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await NotificationService.init();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'foreground_service',
      channelName: 'Hops Service',
      channelDescription: 'Keeps BLE scanning active for emergency alerts',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      autoRunOnBoot: true,
      allowWakeLock: true,
    ),
  );

  await FlutterForegroundTask.startService(
    notificationTitle: 'Hops is active',
    notificationText: 'Scanning for emergency flares…',
  );

  await dotenv.load(fileName: ".env");
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? savedToken = prefs.getString('saved_hops_token');
  final themeIndex = prefs.getInt('selected_theme_index') ?? 0;
  themeNotifier.value = themeIndex;
  fontNotifier.value = prefs.getInt('selected_font_index') ?? -1;
  fontScaleNotifier.value = prefs.getDouble('font_scale') ?? 1.0;

  // App-icon (long-press) shortcuts — see hops_app.dart for what each
  // type actually does. No custom `icon:` per item: that would need real
  // native drawable resources added to the Android project, which isn't
  // something this pass can produce — Android falls back to a sensible
  // default without one rather than failing.
  const quickActions = QuickActions();
  quickActions.initialize((shortcutType) {
    shortcutNotifier.value = shortcutType;
  });
  await quickActions.setShortcutItems(const [
    ShortcutItem(type: 'emergency_flare', localizedTitle: 'Emergency Flare'),
    ShortcutItem(type: 'community_chat', localizedTitle: 'Community Chat'),
  ]);

  runApp(const HopsRoot());
}

class HopsRoot extends StatefulWidget {
  const HopsRoot({super.key});
  @override
  State<HopsRoot> createState() => _HopsRootState();
}

class _HopsRootState extends State<HopsRoot> {
  late int _themeIndex;
  late int _fontIndex;
  late double _fontScale;

  @override
  void initState() {
    super.initState();
    _themeIndex = themeNotifier.value;
    _fontIndex = fontNotifier.value;
    _fontScale = fontScaleNotifier.value;
    themeNotifier.addListener(_onThemeChanged);
    fontNotifier.addListener(_onFontChanged);
    fontScaleNotifier.addListener(_onFontScaleChanged);
  }

  @override
  void dispose() {
    themeNotifier.removeListener(_onThemeChanged);
    fontNotifier.removeListener(_onFontChanged);
    fontScaleNotifier.removeListener(_onFontScaleChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (_themeIndex != themeNotifier.value) {
      setState(() {
        _themeIndex = themeNotifier.value;
      });
    }
  }

  void _onFontChanged() {
    if (_fontIndex != fontNotifier.value) {
      setState(() {
        _fontIndex = fontNotifier.value;
      });
    }
  }

  void _onFontScaleChanged() {
    if (_fontScale != fontScaleNotifier.value) {
      setState(() {
        _fontScale = fontScaleNotifier.value;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppThemes.all[_themeIndex];
    final font = _fontIndex >= 0 && _fontIndex < AppFonts.all.length
        ? AppFonts.all[_fontIndex]
        : null;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.toThemeData(font: font),
      home: _getHomeWidget(),
      builder: (context, child) {
        final mediaQueryData = MediaQuery.of(context);
        // In-app font size (see fontScaleNotifier/font_size_page.dart)
        // replaces the device's own system accessibility text scale here
        // rather than stacking on top of it — same [0.85, 1.6] safety
        // clamp as before, protecting the app's tighter layouts (radar
        // labels, chat bubbles, the nav pill) from breaking at extreme
        // scales, just driven by Hops' own setting instead of the OS one
        // now that there's an in-app control for it.
        final constrainedTextScale = _fontScale.clamp(0.85, 1.6);
        return MediaQuery(
          data: mediaQueryData.copyWith(textScaleFactor: constrainedTextScale),
          child: child!,
        );
      },
    );
  }

  Widget _getHomeWidget() {
    return FutureBuilder<SharedPreferences>(
      future: SharedPreferences.getInstance(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final savedToken = snapshot.data!.getString('saved_hops_token');
        if (savedToken != null) {
          return const HopsApp();
        } else {
          return const HopsRootGatekeeper();
        }
      },
    );
  }
}