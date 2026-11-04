import 'dart:async';
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
import 'package:client/views/hops_splash_screen.dart';
import 'package:client/services/account_standing.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/widgets/alarm_ringing_banner.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:client/services/sos_service.dart';

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

// ── BLE fallback for 1:1 chat ───────────────────────────────────────────
//
// Same "chat screen needs HopsApp's radio" bridge as chatPingRequest
// above, for the DM: transport (see ble_direct_message_service.dart). Only
// HopsApp holds the BLE peripheral/scanner, and IndividualChatTerminalView
// is a pushed screen several routes above it, so requests go down through
// bleDirectMessageOutbox and received messages come back up through
// bleDirectMessageInbox rather than plumbing callbacks through every
// intermediate screen.
class BleDirectMessage {
  final String peerUsername;
  final String text;
  // Only set on outgoing requests, so the chat screen can find out whether
  // the broadcast actually started — HopsApp can refuse (no rotating seed
  // exchanged with this peer yet, so no shared key exists to encrypt
  // with), and a chat screen that assumed success would silently show a
  // message as sent that never left the device. Null on inbound messages,
  // which have nothing to report back.
  final Completer<bool>? sent;
  const BleDirectMessage({
    required this.peerUsername,
    required this.text,
    this.sent,
  });
}

// One-shot, same as chatPingRequest: the chat screen sets it, HopsApp
// broadcasts it and resets it to null.
final ValueNotifier<BleDirectMessage?> bleDirectMessageOutbox =
    ValueNotifier<BleDirectMessage?>(null);

// Broadcast (not single-subscription) so the chat screen can come and go
// without closing the stream out from under HopsApp, which owns it for
// the whole app's lifetime.
final StreamController<BleDirectMessage> bleDirectMessageInbox =
    StreamController<BleDirectMessage>.broadcast();

// Real, measured height (in logical pixels) of HopsApp's floating nav
// pill — arrow handle + gap + the pill itself — refreshed every frame it's
// visible (see hops_app.dart's _buildFloatingNavBar). Exists so a screen
// that has to position its own content just above the pill by hand (e.g.
// Community Alerts' compose bar) can clear it exactly, instead of
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
    foregroundTaskOptions: const ForegroundTaskOptions(
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
  // The saved token is deliberately NOT read here: HopsRoot's own
  // FutureBuilder re-reads it when it builds the home widget, and a copy
  // taken this early would only be a second, staler source of truth.
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
    ShortcutItem(type: 'community_alerts', localizedTitle: 'Community Alerts'),
  ]);

  // Silent SOS Quick Settings tile — see services/sos_service.dart.
  await SosService.init();

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

  // Cold start only. HopsRoot is built once for the process lifetime, so
  // this never re-shows on a theme change, a sign-out, or a return from
  // the background.
  bool _splashDone = false;

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
          data: mediaQueryData.copyWith(textScaler: TextScaler.linear(constrainedTextScale)),
          // Banner sits here, above `child`, rather than inside HopsApp's
          // own Scaffold — HopsApp stays mounted underneath every pushed
          // screen (a chat, settings, a report sheet), so a banner living
          // in ITS body would be hidden behind whatever's on top exactly
          // when someone most needs to reach it. This builder wraps every
          // route the Navigator ever shows, splash and sign-in included, so
          // "an alarm is ringing" stays reachable no matter what's on
          // screen — not just while looking at HopsApp's own tabs.
          child: Column(
            children: [
              const AlarmRingingBanner(),
              Expanded(child: child!),
            ],
          ),
        );
      },
    );
  }

  Widget _getHomeWidget() {
    // Swapped in place as `home` rather than pushed as a route, so the
    // splash physically cannot navigate anywhere itself — it reports that
    // it's done and the signed-in/signed-out decision below still runs
    // exactly as before. A splash that pushed its own destination would
    // route around that check and drop a signed-out user into HopsApp.
    if (!_splashDone) {
      return HopsSplashScreen(
        onFinished: () {
          if (mounted) setState(() => _splashDone = true);
        },
      );
    }
    return FutureBuilder<AccountStanding?>(
      future: _resolveLaunchStanding(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        // null == no usable session: either none was saved, or the one
        // that was is under a moderation block and has just been ended.
        if (snapshot.data == null) return const HopsRootGatekeeper();
        return const HopsApp();
      },
    );
  }

  /// Resolves what the launch path should show: null when there is no
  /// saved session, otherwise this account's moderation standing.
  ///
  /// The standing comes from local storage, NOT from the network. That is
  /// the point — the old launch path checked only that a token existed, so
  /// a banned or suspended user could force-close the app and be back in
  /// until a 30-second poll next happened to succeed, and on an offline
  /// device that was never. Reading the persisted verdict makes a restart
  /// the thing that re-applies the block rather than the thing that shakes
  /// it off. See account_standing.dart.
  ///
  /// A lapsed suspension clears itself inside load(), so this returns
  /// good standing for one that has run its course without needing a
  /// server round trip.
  Future<AccountStanding?> _resolveLaunchStanding() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('saved_hops_token') == null) return null;
    final standing = await AccountStandingStore.instance.load();
    if (!standing.blocksUse) return standing;

    // Blocked: end the session here rather than entering HopsApp and
    // bouncing straight back out of it.
    //
    // The token, and only the token — for a ban as well as a suspension.
    // See endSessionForModeration for why a ban does not wipe either: it is
    // reversible (unban_user), so an unbanned student would otherwise come
    // back to an empty app. my_hops_id stays as the marker of whose data
    // this is, which is what lets sign-in tell "the same person returning"
    // from "somebody else on a shared phone".
    await prefs.remove('saved_hops_token');
    return null;
  }
}