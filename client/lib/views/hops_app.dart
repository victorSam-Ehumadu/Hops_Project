// hops_app.dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypton/crypton.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/main.dart' show shortcutNotifier, nearbyConnectionsSessionCount, chatPingRequest, navBarPillHeightNotifier;
import 'package:client/database/database_helper.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/utils/hop_id_formatter.dart';
import 'package:client/views/radar_screen.dart';
import 'package:client/views/chat_terminal.dart';
import 'package:client/views/contact_profile_screen.dart';
import 'package:client/views/token_generator.dart';
import 'package:client/views/profile_screen.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/models/feature_item.dart';
import 'package:client/views/vibe_check_page.dart';
import 'package:client/views/watch_me_page.dart';
import 'package:client/views/hops_and_robbers.dart';
import 'package:client/views/task_tracker_page.dart';
import 'package:client/views/hops_share_page.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/hops_constants.dart';
import 'package:flutter/services.dart';
import 'package:client/views/community_chat.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/widgets/hops_card.dart';

class HopsApp extends StatefulWidget {
  const HopsApp({super.key});
  @override
  _HopsAppState createState() => _HopsAppState();
}

class _HopsAppState extends State<HopsApp> with WidgetsBindingObserver {
  int _currentIndex = 0;
  // Drives the main-tabs PageView so Home/Contacts/Community/Features/My
  // Features are swipeable, not just reachable via the bottom nav — kept
  // in sync with _currentIndex in both directions (nav tap → animateToPage,
  // swipe → onPageChanged updates _currentIndex).
  late final PageController _pageController = PageController(initialPage: _currentIndex);
  String myUsername = "Loading...";
  List<Map<String, dynamic>> localActiveContacts = [];
  final TextEditingController _manualIdController = TextEditingController();

  // Contacts-tab search — filters the list client-side rather than
  // requiring a fresh query, since localActiveContacts is already the full
  // set loaded locally. Only matters once someone has enough contacts that
  // scrolling to find one gets tedious, so the search bar itself only
  // shows up once there's more than a handful (see _buildContactsTab).
  final TextEditingController _contactSearchController = TextEditingController();
  String _contactSearchQuery = '';
  List<Map<String, dynamic>> get _filteredContacts {
    if (_contactSearchQuery.isEmpty) return localActiveContacts;
    final q = _contactSearchQuery.toLowerCase();
    return localActiveContacts
        .where((c) => (c['username'] as String).toLowerCase().contains(q))
        .toList();
  }

  static const _metaChannel = MethodChannel('com.example.client/rfcomm/meta');

  bool _isFlareActive = false;
  Timer? _flareCancelTimer;
  Timer? _scanRestartTimer;

  // Swiping down on the floating bottom nav pill tucks it off-screen (more
  // room to read, e.g. a long Community Chat thread) — a small up-arrow
  // indicator takes its place so it's still obvious how to bring it back.
  bool _navBarHidden = false;

  // Emergency Flare signing — see hops_constants.dart's flare-sig chunk
  // protocol. _pendingFlareSigChunks/_flareSigHandledNames are keyed by the
  // exact "EMG:<sender>:<reason>" advertisement string, which doubles as
  // both the correlation key for reassembly and the message that was
  // actually signed.
  Timer? _flareSigCycleTimer;
  final Map<String, _FlareSigBuffer> _pendingFlareSigChunks = {};
  final Set<String> _flareSigHandledNames = {};
  Timer? _keyDirectorySyncTimer;

  // Watch Me seed exchange — see hops_constants.dart's watch-seed chunk
  // protocol. Reuses _FlareSigBuffer's shape (just chunks + totalChunks)
  // for reassembly; keyed by the exact "WR:.../WA:..." advertisement
  // string, same correlation-key trick the flare signature buffer uses.
  Timer? _watchSeedCycleTimer;
  final Map<String, _FlareSigBuffer> _pendingWatchSeedChunks = {};
  final Set<String> _watchSeedHandledNames = {};

  // Global task-due reminder — moved here from task_tracker_page.dart,
  // which only ever checked while that exact screen was open and only
  // ever looked at whatever calendar date happened to be selected. See
  // _startTaskReminderCheck.
  Timer? _taskReminderTimer;
  final Set<String> _remindedTaskIds = {};

  // Periodic "did anything about my identity change remotely" check —
  // there's no push-notification infrastructure in this app, so this is
  // a pull-based stand-in: admins get notified about new pending admin
  // requests, everyone else gets notified if their own role just became
  // 'admin'. See _syncIdentityStatus.
  Timer? _identitySyncTimer;
  Set<String>? _seenAdminRequestIds; // null until the first poll sets a baseline

  // Set when the "Emergency Flare" app-icon shortcut fires — tells the
  // freshly-(re)built RadarScreen to auto-open its confirm dialog once,
  // then gets cleared so revisiting Home normally doesn't re-trigger it.
  bool _pendingFlareShortcut = false;

  // Hops & Robbers runner tag — see _advertisePresenceBeacon/_setGameRunnerTag.
  bool _isGameRunnerTagActive = false;
  String? _gameRunnerUsername;

  // True while nearbyConnectionsSessionCount (see main.dart) is above zero —
  // see _pauseBackgroundBleForNearbyConnections/_resumeBackgroundBle... below.
  bool _bleBackgroundPausedForNearbyConnections = false;

  // True once the app-lifecycle handler has actually stopped our presence
  // beacon for being backgrounded — see _handleAppBackgrounded below.
  bool _presencePausedForBackground = false;

  // Discoverable mode — see hops_constants.dart's kDiscoverableProtocolMarker
  // and _advertisePresenceBeacon/_setDiscoverable below. Off by default and
  // never persisted as "on" across the initial load being slow — loaded
  // from SharedPreferences in _loadDiscoverableState so a toggle survives
  // an app restart, but the beacon never goes out with it before that load
  // resolves.
  bool _isDiscoverable = false;

  // This account's role, refreshed at every sign-in (see
  // root_gatekeeper.dart). Gates the Official Alert trigger UI — students
  // never see it at all, not just "see it disabled".
  String _myRole = 'student';
  String? _myAdminTitle;
  bool get _isAdmin => _myRole == 'admin';

  // Admin Official Alert tier (ADM:/ADM_OFF:) — mirrors the Emergency
  // Flare fields above exactly, kept separate so a personal SOS and an
  // Official Alert can be independently active without clobbering each
  // other's cancel/cycle timers.
  bool _isOfficialAlertActive = false;
  Timer? _officialAlertCancelTimer;
  Timer? _officialAlertSigCycleTimer;
  final Set<String> _handledAdmNames = {};
  final Set<String> _handledAdmOffNames = {};

  String? _myAvatarPath;

  String _adUser(String username) =>
      username.length > 9 ? username.substring(0, 9) : username;

  String? _originalBluetoothName;

  DateTime _lastRadarPush = DateTime(2000);   // force immediate first push

  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  bool _bleInitialized = false;

  String? _activePairingCode;
  Timer? _pairingTimeout;

  int _nearbyBleCount = 0;
  Timer? _bleCountTimer;

  // Community Chat chunk-cycling state.
  int _communityMsgCounter = 0;
  Timer? _communityChunkCycleTimer;

  // Rotating presence-beacon identity (see hops_constants.dart). Loaded
  // once from secure storage; _presenceBeaconName() derives the current
  // "HPS:<token>" name from it on demand rather than caching the token
  // itself, since it changes on its own schedule as time passes.
  List<int>? _myRotatingSeed;
  Timer? _rotatingIdRefreshTimer;

  // Known contacts' rotating-ID seeds, keyed by username — resolves an
  // observed beacon token back to a name on Radar. Refreshed alongside the
  // contacts list (see _refreshContactsTrayList) since that's the only
  // thing that changes this: a fresh chat connection populating a seed, or
  // a contact being deleted.
  Map<String, List<int>> _contactSeeds = {};

  Color _bleMeshColor(int count) {
    if (count >= 50) return Colors.green;
    if (count >= 20) return const Color(0xFFF9A825); // amber/yellow
    if (count >= 5)  return Colors.orange;
    return Colors.red;
  }

  // Diagnostic counters
  int _totalScanResults = 0;
  final Set<String> _uniqueHopsDevices = {};
  Timer? _diagTimer;

  // Radar stream
  final _radarStreamController = StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get radarStream => _radarStreamController.stream;

  // At the top, next to the other sets
  final Set<String> _handledWatchAcks = {};
  final Set<String> _handledEmgNames = {};    // dedup for incoming EMG: alerts
  final Set<String> _handledEmgOffNames = {}; // dedup for incoming EMG_OFF: cancels_cance
  final Set<String> _handledChatPingNames = {}; // dedup for incoming CHT: pings

  final _gameEventStreamController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get gameEventStream => _gameEventStreamController.stream;

  // Watch request stream
  late final StreamController<List<String>> _pendingWatchStreamController;
  Stream<List<String>> get pendingWatchStream => _pendingWatchStreamController.stream;

  // Active buddies stream
  late final StreamController<Set<String>> _watchingBuddiesStreamController;
  Stream<Set<String>> get watchingBuddiesStream => _watchingBuddiesStreamController.stream;

  // Feature toggles
  Set<int> enabledFeatureIds = {};
  // My Features display order + pinned set — persisted separately from
  // enabledFeatureIds since "which features are on" and "how they're
  // arranged" are independent concerns. Ids not yet present in
  // _featureOrder (newly enabled features) fall back to catalog order,
  // handled in _orderedEnabledFeatures rather than requiring every
  // enable/disable to rewrite this list.
  List<int> _featureOrder = [];
  Set<int> _pinnedFeatureIds = {};

  // Friend request management
  final List<String> pendingRequests = [];
  final Set<String> _processingAccepts = {};
  Set<String> get friendUsernames =>
      localActiveContacts.map((c) => c['username'] as String).toSet();

  // Watch Me state
  Set<String> _watchingBuddies = {};
  Set<String> _addedFriends = {};
  final List<String> pendingWatchRequests = [];
  final Set<String> _processingWatchAccepts = {};

  // 30-second cooldown for recently handled watch senders
  final Set<String> _recentWatchSenders = {};
  final Map<String, Timer> _recentWatchTimers = {};

  @override
  void initState() {
    super.initState();
    _pendingWatchStreamController = StreamController<List<String>>.broadcast(
      onListen: () => _pendingWatchStreamController.add(List<String>.from(pendingWatchRequests)),
    );
    _watchingBuddiesStreamController = StreamController<Set<String>>.broadcast(
      onListen: () => _watchingBuddiesStreamController.add(Set<String>.from(_watchingBuddies)),
    );

    _loadCurrentIdentityMetrics();
    _captureOriginalBluetoothName();
    _loadEnabledFeatures();
    _loadFeatureOrderAndPins();
    _loadWatchState();
    _loadDiscoverableState();
    _checkPermissionsAndStartBLE();
    _refreshContactsTrayList();
    _maybeShowHelpHint();

    // Best-effort, fire-and-forget — see key_directory.dart. This is what
    // lets Emergency Flare signatures be verified fully offline later,
    // as long as a sync happened at some point while online.
    KeyDirectory.sync();
    _keyDirectorySyncTimer = Timer.periodic(const Duration(minutes: 30), (_) => KeyDirectory.sync());

    _startTaskReminderCheck();
    _identitySyncTimer = Timer.periodic(const Duration(minutes: 3), (_) => _syncIdentityStatus());
    _syncIdentityStatus(); // also run once immediately rather than waiting 3 minutes

    // Dense-BLE-environment insurance (campus vs. home testing showed a
    // real difference here): Android's continuous-scan callback can go
    // quiet for long stretches under heavy ambient BLE traffic — lots of
    // non-Hops devices competing for the same radio — with no error
    // thrown, silently starving Emergency Flare/Watch Me/friend-request/
    // chat-ping reception of the packets they need. Periodically cycling
    // the scan (stop, then start fresh) is a cheap, low-risk way to self-
    // heal from that stall instead of requiring the user to notice and
    // manually pull to refresh. Skipped while a nearby_connections session
    // (chat/Hops Share) is active — that's already a more radio-sensitive
    // window and doesn't need a second source of contention added to it.
    _scanRestartTimer = Timer.periodic(const Duration(minutes: 4), (_) async {
      if (nearbyConnectionsSessionCount.value > 0) return;
      await FlutterBluePlus.stopScan();
      await _startContinuousScan();
    });

    _diagTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      print('📡 [DIAG] BLE scan: ${_totalScanResults} total packets, '
          '${_uniqueHopsDevices.length} unique Hops devices in last 5s');
      _totalScanResults = 0;
      _uniqueHopsDevices.clear();
    });

    WidgetsBinding.instance.addObserver(this);
    nearbyConnectionsSessionCount.addListener(_onNearbyConnectionsSessionCountChanged);
    chatPingRequest.addListener(_onChatPingRequested);
    shortcutNotifier.addListener(_onShortcutTriggered);
    // Cold start: the app-icon shortcut may have already set this before
    // HopsApp even existed (app launched fresh via a shortcut tap) — the
    // listener above only catches taps that happen *while* HopsApp is
    // already mounted (warm start).
    if (shortcutNotifier.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onShortcutTriggered());
    }
  }

  // Handles a tap on any of the app-icon shortcuts registered in
  // main.dart. Consumes (clears) the notifier immediately so this only
  // ever fires once per tap, not repeatedly on every future rebuild.
  void _onShortcutTriggered() {
    final type = shortcutNotifier.value;
    if (type == null) return;
    shortcutNotifier.value = null;
    switch (type) {
      case 'community_chat':
        setState(() => _currentIndex = 2);
        break;
      case 'emergency_flare':
        // Jumps to Home and opens the *same* confirm-then-reason dialog
        // flow the button itself uses — a shortcut skipping straight past
        // that friction would undermine the whole reason it's there.
        setState(() {
          _currentIndex = 0;
          _pendingFlareShortcut = true;
        });
        break;
    }
  }

  // ---------- Presence beacon vs. app lifecycle ----------
  //
  // Backgrounding/closing the app used to leave the presence beacon
  // running indefinitely — flutter_foreground_task keeps the process (and
  // therefore BLE) alive so Emergency Flare/Watch Me/friend requests still
  // arrive while backgrounded, which is by design, but it meant your own
  // dot kept showing up on everyone else's radar too, forever, with no way
  // to tell "actually using the app" from "just left it running." Stopping
  // the beacon outright on every backgrounding would be wrong the other
  // way — a Watch Me buddy tracking you, or a flare/alert mid-broadcast,
  // would silently stop working the moment you background the app to do
  // something else. So: stop advertising on backgrounding ONLY if nothing
  // currently depends on it (no active Watch Me relationship, no live
  // flare/alert), and always resume on foreground. Scanning is untouched
  // either way — receiving an alert must keep working regardless of
  // whether YOUR dot is currently visible to anyone else.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _handleAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _handleAppForegrounded();
    }
  }

  void _handleAppBackgrounded() {
    // A nearby_connections session (chat/Hops Share) already owns pausing
    // and resuming these same timers/beacon for its own reason — defer to
    // it entirely rather than have two mechanisms fight over the same
    // state.
    if (_bleBackgroundPausedForNearbyConnections) return;
    _bleCountTimer?.cancel(); // purely local UI refresh — nothing to update while backgrounded anyway
    if (_watchingBuddies.isEmpty && !_isFlareActive && !_isOfficialAlertActive) {
      _presencePausedForBackground = true;
      _rotatingIdRefreshTimer?.cancel();
      BlePeripheral.stopAdvertising();
    }
  }

  void _handleAppForegrounded() {
    if (_bleBackgroundPausedForNearbyConnections) return;
    _bleCountTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateBleDeviceCount();
    });
    if (_presencePausedForBackground) {
      _presencePausedForBackground = false;
      _advertisePresenceBeacon();
      _startRotatingIdRefreshTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    nearbyConnectionsSessionCount.removeListener(_onNearbyConnectionsSessionCountChanged);
    chatPingRequest.removeListener(_onChatPingRequested);
    shortcutNotifier.removeListener(_onShortcutTriggered);
    _flareCancelTimer?.cancel();
    _bleScanResultsSubscription?.cancel();
    FlutterBluePlus.stopScan();
    BlePeripheral.stopAdvertising();
    _cleanupPairingServer();
    _radarStreamController.close();
    _pendingWatchStreamController.close();
    _watchingBuddiesStreamController.close();
    _gameEventStreamController.close();
    _diagTimer?.cancel();
    _scanRestartTimer?.cancel();
    _bleCountTimer?.cancel();
    _communityChunkCycleTimer?.cancel();
    _rotatingIdRefreshTimer?.cancel();
    _keyDirectorySyncTimer?.cancel();
    _officialAlertCancelTimer?.cancel();
    _officialAlertSigCycleTimer?.cancel();
    _watchSeedCycleTimer?.cancel();
    _taskReminderTimer?.cancel();
    _identitySyncTimer?.cancel();
    for (final timer in _recentWatchTimers.values) {
      timer.cancel();
    }
    _pageController.dispose();
    _contactSearchController.dispose();
    super.dispose();
  }

  // ---------- Watch state persistence ----------
  Future<void> _loadWatchState() async {
    final prefs = await SharedPreferences.getInstance();
    final watching = prefs.getStringList('watchingBuddies') ?? [];
    setState(() => _watchingBuddies = watching.toSet());
    _notifyWatchingBuddiesChanged();
  }

  // ---------- One-time "you can replay Help" hint ----------
  // Set by walkthrough_screen.dart right after someone finishes the
  // first-time onboarding walkthrough — shown once, here, since that's the
  // most reliable place to reach every user regardless of whether they
  // ever go looking for Profile on their own.
  Future<void> _maybeShowHelpHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('pending_help_hint') ?? false)) return;
    await prefs.setBool('pending_help_hint', false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Tip: replay this walkthrough anytime from Profile → Help & Walkthrough."),
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  // ---------- Discoverable mode ----------
  Future<void> _loadDiscoverableState() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('discoverable_mode') ?? false;
    if (saved && mounted) {
      setState(() => _isDiscoverable = true);
      // BLE init may or may not have already sent the first beacon by the
      // time this resolves — re-advertise to make sure a "was on last
      // time" toggle actually goes out, rather than silently staying off
      // until the next unrelated re-advertise happens to fire.
      if (_activePairingCode == null && !_isFlareActive && !_isOfficialAlertActive) {
        _advertisePresenceBeacon();
      }
    }
  }

  // Mirrors _setGameRunnerTag's shape — toggled from Radar's discoverable
  // button. Persisted so it survives an app restart, and re-advertises
  // immediately so turning it on/off is reflected within seconds rather
  // than waiting for the next incidental beacon refresh.
  Future<void> _setDiscoverable(bool value) async {
    setState(() => _isDiscoverable = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('discoverable_mode', value);
    if (_activePairingCode == null && !_isFlareActive && !_isOfficialAlertActive) {
      _advertisePresenceBeacon();
    }
  }

  // ---------- Radio contention with nearby_connections (chat / Hops Share) ----------
  //
  // Root cause of 1:1 chat being unreliable even with every permission
  // granted: it was never actually a permissions problem after
  // _connectWithPermissions() (see chat_terminal.dart) — it was radio
  // contention. HopsChatService.connect() and HopsSharePage both stop BLE
  // peripheral advertising ONCE, right before starting a nearby_connections
  // session — but this HopsApp instance is never disposed while that screen
  // is pushed on top of it (it's a normal Navigator.push, not a replace),
  // so its own background timers keep firing underneath the whole time:
  // _rotatingIdRefreshTimer restarts BLE peripheral advertising every
  // 60 seconds, and _bleCountTimer's _updateBleDeviceCount() does a full
  // stop-scan / unfiltered-scan / stop-scan / restart-filtered-scan cycle
  // every 30 seconds. Both directly fight nearby_connections for the same
  // Bluetooth radio (see hops_chat_service.dart's header comment) — a chat
  // session sits open far longer than a typical Hops Share transfer, so it
  // has far more opportunities for one of these to land mid-handshake and
  // silently kill the connection attempt, which matches "never actually
  // connects" rather than an intermittent drop.
  //
  // Deliberately does NOT stop the continuous filtered scan itself —
  // Emergency Flare/Watch Me/friend requests still need to keep working
  // while a chat is open, and steady-state scanning is far less disruptive
  // than the two repeated stop/restart cycles above.
  void _onNearbyConnectionsSessionCountChanged() {
    if (nearbyConnectionsSessionCount.value > 0) {
      _pauseBackgroundBleForNearbyConnections();
    } else {
      _resumeBackgroundBleAfterNearbyConnections();
    }
  }

  void _pauseBackgroundBleForNearbyConnections() {
    if (_bleBackgroundPausedForNearbyConnections) return;
    _bleBackgroundPausedForNearbyConnections = true;
    _rotatingIdRefreshTimer?.cancel();
    _bleCountTimer?.cancel();
  }

  void _resumeBackgroundBleAfterNearbyConnections() {
    if (!_bleBackgroundPausedForNearbyConnections) return;
    _bleBackgroundPausedForNearbyConnections = false;
    // The closing chat/share screen already restores the plain presence
    // beacon itself (see hops_chat_service.dart/hops_share_page.dart
    // dispose()) — this just picks the two paused timers back up.
    _startRotatingIdRefreshTimer();
    _bleCountTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateBleDeviceCount();
    });
  }

  // ---------- "Come open our chat" ping (CHT:) ----------
  //
  // A chat screen sets chatPingRequest (see main.dart) when it wants to
  // reach a peer who might not currently be running a matching
  // nearby_connections session at all — that transport genuinely cannot
  // reach them in that case, no matter how long it waits. This broadcasts
  // a short, ordinary BLE advertisement instead (same string-prefix
  // mechanism as FR:/WR:/EMG:), which any Hops device with the app
  // running picks up via its always-on scan regardless of what screen
  // it's on.
  void _onChatPingRequested() {
    final peer = chatPingRequest.value;
    if (peer == null) return;
    chatPingRequest.value = null; // one-shot, like shortcutNotifier
    _broadcastChatPing(peer);
  }

  Future<void> _broadcastChatPing(String peerUsername) async {
    // Truncated the same way EMG:/ADM: truncate their sender tag — this is
    // a broadcast-to-everyone-nearby ping (like those), not a
    // rotating-token-addressed one, since the whole point is reaching a
    // peer whose current token we may have no way to know yet (nothing
    // about this app lets you learn a contact's rotating seed before a
    // chat has ever successfully connected).
    final recipientTag =
        peerUsername.length > 8 ? peerUsername.substring(0, 8) : peerUsername;
    try {
      await _advertiseWithName("CHT:$recipientTag:$myUsername", []);
    } catch (_) {
      // Best-effort — worst case the peer just doesn't get pinged this time.
    }
    await Future.delayed(const Duration(seconds: 3));
    // Only resume our own idle presence beacon if nothing else is still
    // actively using the radio for a nearby_connections session — if one
    // is (this ping was fired mid-chat-attempt via
    // IndividualChatTerminalView.pauseForPing), leave BLE peripheral
    // advertising off; that screen brings its own radio use back up right
    // after this same delay via resumeAfterPing().
    if (nearbyConnectionsSessionCount.value == 0 &&
        _activePairingCode == null &&
        !_isFlareActive &&
        !_isOfficialAlertActive) {
      await _advertisePresenceBeacon();
    }
  }

  Future<void> _updateBleDeviceCount() async {
    // Don't interrupt an active pairing handshake
    if (_activePairingCode != null) return;

    await FlutterBluePlus.stopScan();

    final Set<String> uniqueIds = {};
    StreamSubscription<List<ScanResult>>? countSub;

    // Temporary listener on the raw scan stream — counts every visible device
    countSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        uniqueIds.add(r.device.remoteId.toString());
      }
    });

    // Unfiltered 3-second scan — sees ALL BLE devices, not just Hops ones
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      continuousUpdates: true,
    );

    await Future.delayed(const Duration(seconds: 3));
    await countSub.cancel();
    await FlutterBluePlus.stopScan();

    if (mounted) {
      setState(() => _nearbyBleCount = uniqueIds.length);
    }

    // Restart the filtered Hops scan
    await _startContinuousScan();
  }

  // Splits a message into chunks that fit the manufacturer-data budget
  // (see hops_constants.dart) and cycles the peripheral through them via
  // scan-response manufacturer data, keeping the ordinary "HPS:<token>"
  // beacon name unchanged throughout — receivers detect a chunk purely by
  // the presence of our manufacturer ID, not by any change to the name.
  Future<void> _advertiseCommunityMessage(String message) async {
    _communityChunkCycleTimer?.cancel();
    await _ensureRotatingSeedLoaded();

    final msgId = _communityMsgCounter;
    _communityMsgCounter = (_communityMsgCounter + 1) % 256;

    // Computed once and reused for every chunk of this message — the tag
    // has to stay the same across the whole (multi-second) broadcast cycle
    // even if a 15-minute rotation window happens to roll over mid-send,
    // or receivers would see chunks that look like they're from two
    // different senders.
    final senderToken = _myRotatingSeed != null
        ? computeRotatingToken(_myRotatingSeed!)
        : myUsername; // pre-rotating-ID fallback — see _presenceBeaconName()

    final chunks = <String>[];
    for (var i = 0;
        i < message.length && chunks.length < kCommunityMaxChunks;
        i += kCommunityChunkTextBudget) {
      final end = (i + kCommunityChunkTextBudget < message.length)
          ? i + kCommunityChunkTextBudget
          : message.length;
      chunks.add(message.substring(i, end));
    }
    if (chunks.isEmpty) chunks.add('');

    const perChunkDuration = Duration(milliseconds: 1800);
    const totalCycles = 2; // rebroadcast the full sequence twice for reliability

    Future<void> advertiseChunk(int index) => _advertiseWithName(
      _presenceBeaconName(),
      [],
      manufacturerData: ManufacturerData(
        manufacturerId: kCommunityManufacturerId,
        data: encodeCommunityChatChunk(
          senderToken: senderToken,
          msgId: msgId,
          chunkIndex: index,
          totalChunks: chunks.length,
          chunkText: chunks[index],
        ),
      ),
      manufacturerDataInScanResponse: true,
    );

    void step(int chunkIndex, int cycle) {
      advertiseChunk(chunkIndex);
      _communityChunkCycleTimer = Timer(perChunkDuration, () {
        if (chunkIndex + 1 < chunks.length) {
          step(chunkIndex + 1, cycle);
        } else if (cycle + 1 < totalCycles) {
          step(0, cycle + 1);
        } else {
          // Done — drop the manufacturer data and revert to the plain
          // presence beacon.
          BlePeripheral.stopAdvertising();
          _advertisePresenceBeacon();
        }
      });
    }

    step(0, 0);
  }

  Future<void> _captureOriginalBluetoothName() async {
    try {
      final name = await _metaChannel.invokeMethod<String>('getAdapterName');
      if (mounted && name != null && name.isNotEmpty) {
        _originalBluetoothName = name;
      }
    } catch (_) {
      // If unavailable, we simply won't restore — no crash.
    }
  }

  Future<void> _advertiseWithName(
    String localName,
    List<String> services, {
    ManufacturerData? manufacturerData,
    bool manufacturerDataInScanResponse = false,
  }) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: localName,
      services: [HOPS_SERVICE_UUID, ...services], // ← always include Hops UUID
      manufacturerData: manufacturerData,
      addManufacturerDataInScanResponse: manufacturerDataInScanResponse,
    );
    if (_originalBluetoothName != null) {
      Future.delayed(const Duration(milliseconds: 500), () async {
        if (!mounted) return;
        try {
          await _metaChannel.invokeMethod(
            'setAdapterName',
            {'name': _originalBluetoothName!},
          );
        } catch (_) {}
      });
    }
  }

  // Extends an Emergency Flare's (or its cancellation's) reach beyond the
  // originating device's direct BLE range — typically about one floor —
  // by having every device that hears it for the first time re-broadcast
  // the exact same payload for a short window. A device on the floor
  // between the sender and a far device becomes an unwitting relay hop
  // simply by having Hops open; chain enough of them and the flare
  // reaches devices the original sender could never have reached alone.
  //
  // Deliberately NOT used for the "HPS:" presence beacon — relaying that
  // would make Watch Me's RSSI-based proximity read distance-to-relayer
  // instead of distance-to-buddy, which would be actively misleading for
  // a feature whose whole job is estimating how far someone actually is.
  //
  // No hop-count field is embedded in the payload (there's no spare byte
  // in EMG's already-tight 29-byte string budget for one). Instead this
  // relies entirely on the caller's existing "have I seen this exact
  // string before" dedup set — every device relays each distinct flare
  // string at most once, ever, so the flood is bounded by the number of
  // devices that hear it, not by an explicit hop limit, and can't loop.
  void _scheduleEmgRelay(String localName) {
    // Small random jitter so every device that just heard the same
    // broadcast doesn't key up the radio in perfect lockstep and collide.
    final jitter = Duration(milliseconds: 300 + Random().nextInt(700));
    Future.delayed(jitter, () async {
      if (!mounted) return;
      await _advertiseWithName(localName, []);
      Future.delayed(const Duration(seconds: 4), () {
        if (!mounted) return;
        BlePeripheral.stopAdvertising();
        _advertisePresenceBeacon();
      });
    });
  }

  void _cancelEmergencyFlare({bool silent = false}) {
    _flareCancelTimer?.cancel();
    _flareCancelTimer = null;
    _flareSigCycleTimer?.cancel();
    _flareSigCycleTimer = null;

    // Broadcast the cancel signal — receivers listen for EMG_OFF: and dismiss
    final sender = myUsername.length > 8
        ? myUsername.substring(0, 8)
        : myUsername;
    _advertiseWithName("EMG_OFF:$sender", []);

    // After 5 seconds of broadcasting EMG_OFF, revert to normal HPS beacon
    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });

    setState(() => _isFlareActive = false);

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Emergency flare cancelled"),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _broadcastEmergencyFlare(String reason) async {
    // Only cancel the timer — do NOT call _cancelEmergencyFlare here,
    // which would start an HPS advertisement we'd immediately kill anyway.
    _flareCancelTimer?.cancel();
    _flareCancelTimer = null;

    final maxSenderLen = 8;
    final maxReasonLen = 14;
    final sender = myUsername.length > maxSenderLen
        ? myUsername.substring(0, maxSenderLen)
        : myUsername;
    final shortReason = reason.length > maxReasonLen
        ? reason.substring(0, maxReasonLen)
        : reason;

    final advName = "EMG:$sender:$shortReason";

    // _advertiseWithName's BlePeripheral calls used to be awaited bare —
    // any transient failure (adapter mid-toggle from another in-flight
    // advertise call, the previous stopAdvertising not yet released,
    // Bluetooth off, a missing permission) threw silently into a fire-
    // and-forget call with no user-facing sign anything went wrong, so
    // the flare looked "sometimes just doesn't work." This is safety-
    // critical, so retry a few times before actually giving up and
    // telling the user.
    bool started = false;
    Object? lastError;
    for (var attempt = 0; attempt < 3 && !started; attempt++) {
      try {
        await _advertiseWithName(advName, []);
        started = true;
      } catch (e) {
        lastError = e;
        if (attempt < 2) await Future.delayed(const Duration(milliseconds: 400));
      }
    }

    if (!started) {
      print("❌ Emergency flare failed to broadcast: $lastError");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                "⚠️ Emergency flare failed to start. Check Bluetooth is on and try again."),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: "RETRY",
              textColor: Colors.white,
              onPressed: () => _broadcastEmergencyFlare(reason),
            ),
          ),
        );
      }
      return; // never claim it's active when it isn't
    }
    print("🚨 Broadcasting emergency: $advName");

    setState(() => _isFlareActive = true);
    // Fail-open, verify-after: the alert above is already live and audible
    // on nearby devices by the time this signature has even finished
    // computing, let alone finished trickling across in chunks. Speed
    // matters more than proof for the first instant of a safety alert;
    // this only upgrades the notification a few seconds later.
    _startSignatureCycle(
      advName,
      isActive: () => _isFlareActive,
      setCycleTimer: (t) => _flareSigCycleTimer = t,
    );

    // Auto-cancel after 30 seconds
    _flareCancelTimer = Timer(const Duration(seconds: 30), () {
      _cancelEmergencyFlare(silent: true);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Emergency flare active for 30 seconds"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: "CANCEL",
            textColor: Colors.white,
            onPressed: _cancelEmergencyFlare,
          ),
        ),
      );
    }
  }

  // ---------- Admin Official Alert (ADM:/ADM_OFF:) ----------
  // Deliberately near-identical in shape to _cancelEmergencyFlare/
  // _broadcastEmergencyFlare above rather than parametrized into one
  // implementation — the two tiers' trigger paths, timers, and UI text
  // are independent by design (see _isAdmin gating the trigger itself),
  // and keeping them as separate, readable methods matches this file's
  // existing style (FR/FA/WR/WA are all separate too) rather than adding
  // a layer of indirection for two call sites.

  void _cancelOfficialAlert({bool silent = false}) {
    _officialAlertCancelTimer?.cancel();
    _officialAlertCancelTimer = null;
    _officialAlertSigCycleTimer?.cancel();
    _officialAlertSigCycleTimer = null;

    final sender = myUsername.length > 8 ? myUsername.substring(0, 8) : myUsername;
    _advertiseWithName("ADM_OFF:$sender", []);

    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });

    setState(() => _isOfficialAlertActive = false);

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Official alert cancelled"),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _broadcastOfficialAlert(String reason) async {
    if (!_isAdmin) return; // UI already gates this, but never trust that alone
    _officialAlertCancelTimer?.cancel();
    _officialAlertCancelTimer = null;

    final maxSenderLen = 8;
    final maxReasonLen = 14;
    final sender = myUsername.length > maxSenderLen
        ? myUsername.substring(0, maxSenderLen)
        : myUsername;
    final shortReason = reason.length > maxReasonLen
        ? reason.substring(0, maxReasonLen)
        : reason;

    final advName = "ADM:$sender:$shortReason";

    // Same retry-then-report treatment as _broadcastEmergencyFlare above —
    // see its comment for why an unguarded single await here was a real
    // "silently does nothing" failure mode.
    bool started = false;
    Object? lastError;
    for (var attempt = 0; attempt < 3 && !started; attempt++) {
      try {
        await _advertiseWithName(advName, []);
        started = true;
      } catch (e) {
        lastError = e;
        if (attempt < 2) await Future.delayed(const Duration(milliseconds: 400));
      }
    }

    if (!started) {
      print("❌ Official alert failed to broadcast: $lastError");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                "⚠️ Official alert failed to start. Check Bluetooth is on and try again."),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 8),
            action: SnackBarAction(
              label: "RETRY",
              textColor: Colors.white,
              onPressed: () => _broadcastOfficialAlert(reason),
            ),
          ),
        );
      }
      return;
    }
    print("🔴 Broadcasting official alert: $advName");

    setState(() => _isOfficialAlertActive = true);
    _startSignatureCycle(
      advName,
      isActive: () => _isOfficialAlertActive,
      setCycleTimer: (t) => _officialAlertSigCycleTimer = t,
    );

    _officialAlertCancelTimer = Timer(const Duration(seconds: 30), () {
      _cancelOfficialAlert(silent: true);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Official alert active for 30 seconds"),
          backgroundColor: Colors.red.shade900,
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: "CANCEL",
            textColor: Colors.white,
            onPressed: _cancelOfficialAlert,
          ),
        ),
      );
    }
  }

  // Signs [advName] (the exact alert string already being broadcast — a
  // flare or an Official Alert, both share this) with this device's own
  // private key, then cycles the signature across manufacturer-data
  // chunks alongside it — same cadence/cycling pattern as
  // _advertiseCommunityMessage, but the local *name* stays fixed at
  // advName throughout instead of reverting to the presence beacon, since
  // the alert itself is what needs to keep advertising. [isActive] and
  // [setCycleTimer] let one implementation serve both the personal-SOS and
  // Official Alert timer/state fields without them clobbering each other.
  //
  // Scope note: only the originating device ever signs/sends chunks — a
  // relayed alert (_scheduleEmgRelay) re-broadcasts the plain name for
  // range extension but doesn't carry signature chunks, since a relay
  // node has no way to re-sign on the original sender's behalf. Signature
  // verification is therefore only possible within direct BLE range of
  // whoever actually triggered the alert — a known, accepted limitation
  // for this pass rather than a full relay-aware signing scheme.
  Future<void> _startSignatureCycle(
    String advName, {
    required bool Function() isActive,
    required void Function(Timer?) setCycleTimer,
  }) async {
    setCycleTimer(null);
    try {
      const storage = FlutterSecureStorage();
      final privateKeyStr = await storage.read(key: 'private_key');
      if (privateKeyStr == null) return; // nothing to sign with
      final privateKey = RSAPrivateKey.fromString(privateKeyStr);
      final signature =
          privateKey.createSHA256Signature(Uint8List.fromList(utf8.encode(advName)));

      final chunks = <List<int>>[];
      for (var i = 0; i < signature.length; i += kFlareSigChunkBudgetBytes) {
        final end = (i + kFlareSigChunkBudgetBytes < signature.length)
            ? i + kFlareSigChunkBudgetBytes
            : signature.length;
        chunks.add(signature.sublist(i, end));
      }
      if (chunks.isEmpty) return;

      const perChunkDuration = Duration(milliseconds: 1200);
      const totalCycles = 3; // more reliability margin than Community Chat — this one's safety-critical

      void step(int index, int cycle) {
        if (!isActive()) return; // cancelled/expired mid-cycle — stop
        _advertiseWithName(
          advName,
          [],
          manufacturerData: ManufacturerData(
            manufacturerId: kCommunityManufacturerId,
            data: encodeFlareSigChunk(
              chunkIndex: index,
              totalChunks: chunks.length,
              chunkBytes: chunks[index],
            ),
          ),
          manufacturerDataInScanResponse: true,
        );
        setCycleTimer(Timer(perChunkDuration, () {
          if (index + 1 < chunks.length) {
            step(index + 1, cycle);
          } else if (cycle + 1 < totalCycles) {
            step(0, cycle + 1);
          }
          // Done cycling — advName keeps advertising (name unchanged)
          // without further manufacturer data until cancel/expiry.
        }));
      }

      step(0, 0);
    } catch (e) {
      print("⚠️ Failed to sign alert: $e");
    }
  }

  // Called once an alert's signature chunks (broadcast alongside [advName]
  // itself — see above) have fully reassembled. Looks up candidate
  // directory entries for the truncated sender via KeyDirectory and
  // upgrades the notification accordingly. [requireAdmin] distinguishes
  // the two tiers: a personal SOS accepts any valid signature; an
  // Official Alert additionally requires the signer's cached role to
  // actually be 'admin' — a candidate that signs correctly but isn't an
  // admin is skipped, not accepted, since this is the exact spoofing case
  // the whole tier exists to prevent.
  Future<void> _verifySignedAlert(
    String advName,
    Uint8List signature, {
    required bool requireAdmin,
  }) async {
    if (_flareSigHandledNames.contains(advName)) return;
    _flareSigHandledNames.add(advName);
    Future.delayed(const Duration(seconds: 40), () => _flareSigHandledNames.remove(advName));

    final payload = advName.substring(4); // strip "EMG:" or "ADM:" — both 4 chars
    final parts = payload.split(':');
    final sender = parts.isNotEmpty ? parts[0] : '';
    final reason = parts.length > 1 ? parts.sublist(1).join(':') : 'Emergency';
    if (sender.isEmpty) return;

    final candidates = await KeyDirectory.candidatesForTruncatedUsername(sender);
    for (final candidate in candidates) {
      final entry = candidate.value;
      if (requireAdmin && entry.role != 'admin') continue;
      try {
        final publicKey = RSAPublicKey.fromString(entry.publicKey);
        final valid = publicKey.verifySHA256Signature(
          Uint8List.fromList(utf8.encode(advName)),
          signature,
        );
        if (valid) {
          if (requireAdmin) {
            await NotificationService.updateOfficialAlertVerificationStatus(
                sender: sender, reason: reason, adminTitle: entry.adminTitle, verified: true);
          } else {
            await NotificationService.updateEmergencyVerificationStatus(
                sender: sender, reason: reason, verified: true);
          }
          return;
        }
      } catch (_) {
        // Malformed candidate key or signature mismatch — try the next one.
      }
    }
    if (requireAdmin) {
      // No valid *admin* signature found — reject outright rather than
      // downgrade to "Unverified", since an unverified claim of
      // officialdom is actively misleading in a way an unverified
      // personal report isn't.
      await NotificationService.updateOfficialAlertVerificationStatus(
          sender: sender, reason: reason, verified: false);
      return;
    }
    await NotificationService.updateEmergencyVerificationStatus(
        sender: sender, reason: reason, verified: false);
  }

  Future<void> _saveWatchState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('watchingBuddies', _watchingBuddies.toList());
  }

  void _notifyWatchRequestsChanged() {
    _pendingWatchStreamController.add(List<String>.from(pendingWatchRequests));
  }

  void _notifyWatchingBuddiesChanged() {
    _watchingBuddiesStreamController.add(Set<String>.from(_watchingBuddies));
  }

  void clearAllWatchState() {
    setState(() {
      _watchingBuddies.clear();
      pendingWatchRequests.clear();
      _recentWatchSenders.clear();
      for (final timer in _recentWatchTimers.values) {
        timer.cancel();
      }
      _recentWatchTimers.clear();
      _saveWatchState();
      _notifyWatchingBuddiesChanged();
      _notifyWatchRequestsChanged();
      _handledWatchAcks.clear();
    });
  }

  // ---------- Friend request logic ----------
  // Targets whoever is *currently* broadcasting [targetToken] — RadarScreen
  // already handles the "already a friend" check itself (it knows the
  // resolved username when there is one; this only ever sees the token).
  // myUsername rides along as a deliberate self-disclosure: the recipient
  // learns who's requesting even though the request was addressed at an
  // anonymous, ever-changing token rather than a name.
  Future<void> sendFriendRequest(String targetToken) async {
    final advName = "FR:$targetToken:${_adUser(myUsername)}";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 10), () {
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });
  }

  Future<void> _advertiseVibeTag(String location, int level) async {
    final advName = "VBT:$location:$level";
    if (advName.length > 29) { _showToastFeedbackAlert("Location name too long"); return; }
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 30), () {
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  Future<void> acceptFriendRequest(String sender) async {
    final advName = "FA:${_adUser(sender)}:${_adUser(myUsername)}";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    if (!_addedFriends.contains(sender)) {
      _addedFriends.add(sender);
      await _refreshContactsTrayList();
    }
    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });
  }

  void acceptRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() => pendingRequests.remove(sender));
    acceptFriendRequest(sender).then((_) => _processingAccepts.remove(sender));
  }

  void declineRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() => pendingRequests.remove(sender));
    Future.delayed(const Duration(seconds: 2), () => _processingAccepts.remove(sender));
  }

  // ---------- Watch request handling ----------
  void acceptWatchRequestFromCard(String sender) {
    _processingWatchAccepts.add(sender);
    setState(() => pendingWatchRequests.remove(sender));
    _notifyWatchRequestsChanged();
    _watchingBuddies.add(sender);
    _saveWatchState();
    _notifyWatchingBuddiesChanged();
    _acceptWatchRequestBle(sender);
    _addRecentWatchSender(sender);
    Future.delayed(const Duration(seconds: 2), () => _processingWatchAccepts.remove(sender));
  }

  void declineWatchRequestFromCard(String sender) {
    _processingWatchAccepts.add(sender);
    setState(() => pendingWatchRequests.remove(sender));
    _notifyWatchRequestsChanged();
    _addRecentWatchSender(sender);
    Future.delayed(const Duration(seconds: 2), () => _processingWatchAccepts.remove(sender));
  }

  void _addRecentWatchSender(String sender) {
    _recentWatchSenders.add(sender);
    _recentWatchTimers[sender]?.cancel();
    _recentWatchTimers[sender] = Timer(const Duration(seconds: 30), () {
      _recentWatchSenders.remove(sender);
      _recentWatchTimers.remove(sender);
    });
  }

  Future<void> _acceptWatchRequestBle(String sender) async {
    final advName = "WA:${_adUser(sender)}:${_adUser(myUsername)}";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    // Cycle our own seed alongside the accept so sender's device learns
    // how to recognize our beacon too — Watch Me relationships work in
    // both directions, and neither side should need a separate chat for
    // this to actually function.
    _cycleWatchSeedChunks(advName, const Duration(seconds: 5));
    Future.delayed(const Duration(seconds: 5), () {
      _watchSeedCycleTimer?.cancel();
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });
  }

  // Cycles this device's own rotating-ID seed across manufacturer-data
  // chunks alongside [advName] for [duration] — same cadence/shape as
  // _startSignatureCycle, minus the signing step (the seed is static, so
  // there's nothing to compute per call, just chunk and repeat). Lets a
  // Watch request/accept teach the other device how to recognize this
  // device's beacon without either side ever needing to have chatted —
  // see hops_constants.dart's watch-seed chunk protocol.
  void _cycleWatchSeedChunks(String advName, Duration duration) {
    _watchSeedCycleTimer?.cancel();
    final seed = _myRotatingSeed;
    if (seed == null) return; // pre-rotating-ID account — nothing to share

    final chunks = <List<int>>[];
    for (var i = 0; i < seed.length; i += kWatchSeedChunkBudgetBytes) {
      final end = (i + kWatchSeedChunkBudgetBytes < seed.length)
          ? i + kWatchSeedChunkBudgetBytes
          : seed.length;
      chunks.add(seed.sublist(i, end));
    }
    if (chunks.isEmpty) return;

    const perChunkDuration = Duration(milliseconds: 500);
    final endTime = DateTime.now().add(duration);

    void step(int index) {
      if (!mounted || DateTime.now().isAfter(endTime)) return;
      _advertiseWithName(
        advName,
        [],
        manufacturerData: ManufacturerData(
          manufacturerId: kCommunityManufacturerId,
          data: encodeWatchSeedChunk(
            chunkIndex: index,
            totalChunks: chunks.length,
            chunkBytes: chunks[index],
          ),
        ),
        manufacturerDataInScanResponse: true,
      );
      _watchSeedCycleTimer = Timer(perChunkDuration, () => step((index + 1) % chunks.length));
    }

    step(0);
  }

  // Reassembles watch-seed chunks riding alongside a WR:/WA: advertisement
  // (see _cycleWatchSeedChunks above / hops_constants.dart's watch-seed
  // chunk protocol) and, once complete, saves it as [peer]'s rotating-ID
  // seed — the exact same persistence call chat_terminal.dart's first-chat
  // handshake uses, so Radar and Watch Me can't tell the difference
  // afterwards between a contact learned via chat vs. via a watch request.
  Future<void> _handleIncomingWatchSeedChunk({
    required String name,
    required String peer,
    required ScanResult r,
  }) async {
    final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
    if (mfgBytes == null || _watchSeedHandledNames.contains(name)) return;
    final decoded = decodeWatchSeedChunk(mfgBytes);
    if (decoded == null) return;

    final buffer = _pendingWatchSeedChunks.putIfAbsent(
        name, () => _FlareSigBuffer(decoded.totalChunks));
    buffer.chunks[decoded.chunkIndex] = decoded.bytes;
    buffer.lastSeen = DateTime.now();

    if (buffer.isComplete) {
      _pendingWatchSeedChunks.remove(name);
      _watchSeedHandledNames.add(name);
      Future.delayed(const Duration(seconds: 40), () => _watchSeedHandledNames.remove(name));
      await DatabaseHelper.instance
          .upsertContactRotatingSeed(peer, base64Encode(buffer.reassembled));
      await _refreshContactsTrayList(); // reloads _contactSeeds too
    }

    final staleCutoff = DateTime.now().subtract(const Duration(seconds: 20));
    _pendingWatchSeedChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));
  }

  void _onWatchRequestAccepted(String buddy) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("$buddy accepted your watch request")),
    );
    // The SnackBar only ever reached someone already looking at this
    // screen — this is what reaches them anywhere else in the app.
    NotificationService.showWatchAcceptedNotification(username: buddy);
  }

  Future<void> sendWatchRequest(String targetUsername) async {
    if (_watchingBuddies.contains(targetUsername)) {
      _showToastFeedbackAlert("Already watching $targetUsername");
      return;
    }
    final advName = "WR:${_adUser(targetUsername)}:${_adUser(myUsername)}";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    // Cycle our own seed alongside the request — once they accept, they
    // already have what's needed to recognize our beacon and start
    // watching us for real, with no chat ever required.
    _cycleWatchSeedChunks(advName, const Duration(seconds: 10));
    Future.delayed(const Duration(seconds: 10), () {
      _watchSeedCycleTimer?.cancel();
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
    });
  }

  void stopWatchingBuddy(String buddy) {
    setState(() {
      _watchingBuddies.remove(buddy);
      _saveWatchState();
      _notifyWatchingBuddiesChanged();
    });
    _addRecentWatchSender(buddy);
  }

  // ---------- Permissions & BLE ----------
  Future<void> _checkPermissionsAndStartBLE() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location, Permission.bluetoothAdvertise,
      Permission.bluetoothConnect, Permission.bluetoothScan,
    ].request();
    bool granted = statuses[Permission.location]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted;
    if (!granted) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HopsRootGatekeeper()),
              (route) => false,
        );
      }
      return;
    }
    _initializeParallelBleTransceiverEngine();
  }

  Future<void> _loadCurrentIdentityMetrics() async {
    final prefs = await SharedPreferences.getInstance();
    final avatarPath = prefs.getString('avatar_path');
    setState(() {
      myUsername = prefs.getString('my_username') ?? 'Unknown_User';
      _myAvatarPath = avatarPath;
      // Refreshed at every sign-in (see root_gatekeeper.dart) — gates
      // whether the Official Alert trigger UI shows on Radar/Home at all.
      _myRole = prefs.getString('my_role') ?? 'student';
      _myAdminTitle = prefs.getString('my_admin_title');
    });
  }

  // Checks every incomplete task with a due date against "now", not just
  // whatever's on the currently-selected calendar date in Task Tracker —
  // and runs for as long as HopsApp itself is alive, not just while that
  // one screen happens to be open. Fires a real notification instead of
  // an in-app dialog, which could never have reached you anywhere else.
  void _startTaskReminderCheck() {
    _taskReminderTimer?.cancel();
    _taskReminderTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final tasks = await DatabaseHelper.instance.getTasks();
      for (final task in tasks) {
        final id = task[DatabaseHelper.taskColId] as String;
        if (task[DatabaseHelper.taskColCompleted] == 0 &&
            task[DatabaseHelper.taskColDueDate] != null &&
            (task[DatabaseHelper.taskColDueDate] as int) <= now &&
            !_remindedTaskIds.contains(id)) {
          _remindedTaskIds.add(id);
          await NotificationService.showTaskReminderNotification(
              taskTitle: task[DatabaseHelper.taskColTitle] as String);
        }
      }
    });
  }

  // Pull-based stand-in for push notifications (see field comments above).
  // Best-effort — a failed/offline poll just tries again next cycle
  // rather than surfacing an error for what's meant to be invisible
  // background housekeeping.
  Future<void> _syncIdentityStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) return;
    try {
      if (_isAdmin) {
        final rows = await Supabase.instance.client
            .rpc('list_pending_admin_requests', params: {'p_hops_token': token});
        final ids = (rows as List).map((r) => (r as Map)['id'] as String).toSet();
        final previouslySeen = _seenAdminRequestIds;
        if (previouslySeen != null) {
          final newOnes = ids.difference(previouslySeen);
          if (newOnes.isNotEmpty) {
            await NotificationService.showAdminRequestSubmittedNotification(
                pendingCount: ids.length);
          }
        }
        _seenAdminRequestIds = ids;
      } else {
        final response = await Supabase.instance.client
            .rpc('get_my_status', params: {'p_hops_token': token}).maybeSingle();
        if (response != null && response['role'] == 'admin' && _myRole != 'admin') {
          await prefs.setString('my_role', 'admin');
          final adminTitle = response['admin_title'] as String?;
          if (adminTitle != null) await prefs.setString('my_admin_title', adminTitle);
          setState(() {
            _myRole = 'admin';
            _myAdminTitle = adminTitle;
          });
          await NotificationService.showAdminRequestApprovedNotification();
        }
      }
    } catch (_) {
      // Offline or Supabase unreachable — try again on the next cycle.
    }
  }

  // Loads the rotating-ID seed generated at signup/sign-in (see
  // root_gatekeeper.dart) if not already cached. Awaited before the first
  // presence advertisement so that beacon is never accidentally sent with
  // the plaintext-username fallback _presenceBeaconName() otherwise uses.
  Future<void> _ensureRotatingSeedLoaded() async {
    if (_myRotatingSeed != null) return;
    const storage = FlutterSecureStorage();
    final seedB64 = await storage.read(key: 'rotating_id_seed');
    if (seedB64 == null) return;
    try {
      _myRotatingSeed = base64Decode(seedB64);
    } catch (_) {
      // Corrupt value — fall back to the plaintext beacon rather than crash.
    }
  }

  String _presenceBeaconName() {
    final seed = _myRotatingSeed;
    if (seed == null) {
      // Only reachable if _ensureRotatingSeedLoaded() hasn't resolved yet
      // (or this account predates the rotating-ID feature and has no seed
      // at all) — falls back to the old plaintext beacon rather than not
      // advertising anything.
      return "HPS:$myUsername";
    }
    return "HPS:${computeRotatingToken(seed)}";
  }

  // Every "go back to just being present" call site funnels through here
  // instead of calling _advertiseWithName(_presenceBeaconName(), [])
  // directly, so the Hops & Robbers runner tag (see hops_constants.dart)
  // rides along automatically wherever the presence beacon would
  // otherwise be re-advertised — without every one of those ~10 call
  // sites needing to individually know or care whether a game is active.
  Future<void> _advertisePresenceBeacon() {
    final runnerUsername = _gameRunnerUsername;
    if (_isGameRunnerTagActive && runnerUsername != null) {
      return _advertiseWithName(
        _presenceBeaconName(),
        [],
        manufacturerData: ManufacturerData(
          manufacturerId: kCommunityManufacturerId,
          data: encodeGameRunnerTag(runnerUsername),
        ),
        manufacturerDataInScanResponse: true,
      );
    }
    // Discoverable mode rides the same single manufacturer-data slot the
    // game tag uses — the two are mutually exclusive in practice (an
    // active Hops & Robbers runner tag wins if somehow both are on at
    // once), so this only ever kicks in outside a game.
    if (_isDiscoverable) {
      return _advertiseWithName(
        _presenceBeaconName(),
        [],
        manufacturerData: ManufacturerData(
          manufacturerId: kCommunityManufacturerId,
          data: encodeDiscoverableName(myUsername),
        ),
        manufacturerDataInScanResponse: true,
      );
    }
    return _advertiseWithName(_presenceBeaconName(), []);
  }

  // Called by HopsAndRobbersPage when this device becomes (or stops being)
  // a runner in an active game — see hops_and_robbers.dart's onSetGameRunnerTag.
  void _setGameRunnerTag(bool active) {
    _isGameRunnerTagActive = active;
    _gameRunnerUsername = active ? myUsername : null;
    // Re-advertise immediately rather than waiting for the next periodic
    // refresh — a robber's proximity scan should pick up a fresh runner
    // (or stop seeing a caught one) without a up-to-1-minute lag.
    if (_activePairingCode == null && !_isFlareActive && !_isOfficialAlertActive) {
      _advertisePresenceBeacon();
    }
  }

  // Keeps the beacon's rotating token current while the app just sits idle
  // — nothing else in this file re-advertises on its own once a window
  // rolls over, since every other advertisement flow only reverts to the
  // presence beacon after its own short-lived action finishes.
  void _startRotatingIdRefreshTimer() {
    _rotatingIdRefreshTimer?.cancel();
    _rotatingIdRefreshTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      // Skip while something more important is actively advertising —
      // pairing, Emergency Flare, and Official Alert all run their own
      // short-lived advertisement windows that this shouldn't clobber.
      if (_activePairingCode != null || _isFlareActive || _isOfficialAlertActive) return;
      _advertisePresenceBeacon();
    });
  }

  void _initializeParallelBleTransceiverEngine() async {
    if (_bleInitialized) return;
    _bleInitialized = true;
    await BlePeripheral.initialize();
    await _ensureRotatingSeedLoaded();
    try {
      await _advertisePresenceBeacon();
      _startRotatingIdRefreshTimer();
      print('✅ Advertising started successfully');
    } catch (e) {
      print('❌ Advertising failed: $e');
    }
    _bleScanResultsSubscription = FlutterBluePlus.scanResults.listen((results) async {
      _totalScanResults += results.length;

      for (final r in results) {
        final advName = r.advertisementData.advName;
        if (advName.startsWith("HPS:")) {
          // Dedup by the advertised rotating token, NOT r.device.remoteId.
          // _advertiseWithName() does a stopAdvertising()+startAdvertising()
          // on every single re-advertise — which happens often (rotating-ID
          // refresh every minute, plus mid-cycle restarts from Community
          // Chat/Watch Me seed exchange/flare signature cycling) — and on
          // Android that can hand back a new random advertising address
          // each time. Deduping by remoteId meant one physical device
          // restarting its advertisement mid-window got counted as multiple
          // "unique" devices, which is exactly what inflated this diag
          // count. The rotating token stays fixed for a full 15-minute
          // window regardless of how many times the address changes, so it
          // actually identifies "one device" correctly.
          _uniqueHopsDevices.add(advName.substring(4));
        }
      }

      // Throttle: only forward results every 500ms when in noise mode
      if (DateTime.now().difference(_lastRadarPush).inMilliseconds >= 500) {
        _radarStreamController.add(results);
        _lastRadarPush = DateTime.now();
      }

      for (final r in results) {
        final name = r.advertisementData.advName;
        // ACK
        if (name.startsWith("ACK:") && _activePairingCode != null) {
          final parts = name.substring(4).split(":");
          if (parts.length == 2 && parts[0] == _activePairingCode) {
            final user = parts[1];
            if (!localActiveContacts.any((c) => c['username'] == user)) {
              await _writeContactLogToDatabase(user, "Mutual pairing via code");
            }
          }
        }
        // Friend request — targeted at a rotating token now, not a
        // username, so matching means "is this token mine right now"
        // rather than a plain string comparison.
        if (name.startsWith("FR:")) {
          final parts = name.substring(3).split(":");
          if (parts.length == 2 &&
              _myRotatingSeed != null &&
              matchesRotatingToken(_myRotatingSeed!, parts[0])) {
            final sender = parts[1];
            if (!friendUsernames.contains(sender) &&
                !pendingRequests.contains(sender) &&
                !_processingAccepts.contains(sender)) {
              setState(() => pendingRequests.add(sender));
              await NotificationService.showFriendRequestNotification(sender: sender);
            }
          }
        }
        // Friend ACK
        if (name.startsWith("FA:")) {
          final parts = name.substring(3).split(":");
          if (parts.length == 2 && parts[0] == _adUser(myUsername)) {
            if (!_addedFriends.contains(parts[1])) {
              _addedFriends.add(parts[1]);
              await _refreshContactsTrayList();
              await NotificationService.showFriendAcceptedNotification(username: parts[1]);
            }
          }
        }

        // "Come open our chat" ping — see _broadcastChatPing above. Uses
        // the same truncated-plaintext-username addressing as EMG:/ADM:,
        // not a rotating token, since a chat that's never connected has no
        // way to have exchanged seeds yet.
        if (name.startsWith("CHT:")) {
          final parts = name.substring(4).split(':');
          if (parts.length == 2) {
            final myTruncated =
                myUsername.length > 8 ? myUsername.substring(0, 8) : myUsername;
            if (parts[0] == myTruncated) {
              final sender = parts[1];
              if (!_handledChatPingNames.contains(name)) {
                _handledChatPingNames.add(name);
                Future.delayed(const Duration(seconds: 5), () {
                  _handledChatPingNames.remove(name);
                });
                await NotificationService.showChatInviteNotification(sender: sender);
              }
            }
          }
        }

        // Watch request
        if (name.startsWith("WR:")) {
          final parts = name.substring(3).split(":");
          if (parts.length == 2 && parts[0] == _adUser(myUsername)) {
            final sender = parts[1];
            if (!_recentWatchSenders.contains(sender) &&
                !pendingWatchRequests.contains(sender) &&
                !_processingWatchAccepts.contains(sender)) {
              _addRecentWatchSender(sender);
              setState(() => pendingWatchRequests.add(sender));
              _notifyWatchRequestsChanged();
              await NotificationService.showWatchRequestNotification(sender: sender);
            }
            // The sender's rotating-ID seed rides alongside the WR: name
            // for its whole cycling window — reassemble regardless of
            // whether we've already recorded this exact request, so a
            // lingering rebroadcast still finishes teaching us their seed.
            // This is what lets Watch Me work on a friend you've never
            // actually chatted with.
            await _handleIncomingWatchSeedChunk(name: name, peer: sender, r: r);
          }
        }

        // Watch ACK – permanent one‑time snackbar
        if (name.startsWith("WA:")) {
          final parts = name.substring(3).split(":");
          if (parts.length == 2 && parts[0] == _adUser(myUsername)) {
            final sender = parts[1];
            if (!_handledWatchAcks.contains(sender)) {
              _handledWatchAcks.add(sender);
              _onWatchRequestAccepted(sender);
            }
            // Same seed exchange as WR: above, other direction — lets the
            // original requester recognize the accepter's beacon too.
            await _handleIncomingWatchSeedChunk(name: name, peer: sender, r: r);
          }
        }

        // Tag game
        if (name.startsWith("TAG:")) {
          final parts = name.substring(4).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            final tagger = parts[1];
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: const Text("You've been tagged!"),
                content: Text("$tagger tagged you!"),
                actions: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text("OK"),
                  ),
                ],
              ),
            );
          }
        }
        // Hops & Robbers game actions
        if (name.startsWith("GAME_")) {
          final parts = name.substring(5).split(":");
          if (parts.length == 2) {
            final action = parts[0];
            final data = <String, String>{};
            for (final pair in parts[1].split(';')) {
              final kv = pair.split('=');
              if (kv.length == 2) data[kv[0]] = kv[1];
            }
            _gameEventStreamController.add({'action': action, 'data': data});
          }
        }
        // Emergency Flare (with reason parsing)
        if (name.startsWith("EMG:")) {
          // Ignore own flares (we're the sender) — must be an exact match
          // on the sender segment up to the next colon, not a startsWith
          // on the whole remainder. A prefix check here used to silently
          // drop (never notify, never relay) anyone else's real flare
          // whenever their truncated username merely started with ours —
          // e.g. "Vic" would swallow a flare from "Victor12", which is
          // exactly the kind of name collision two test accounts on the
          // same campus are likely to hit.
          final myTruncated = myUsername.length > 8 ? myUsername.substring(0, 8) : myUsername;
          final emgSender = name.substring(4).split(':').first;
          if (emgSender != myTruncated) {
            // Set dedup: same advertisement name → processed exactly once
            if (!_handledEmgNames.contains(name)) {
              _handledEmgNames.add(name);
              // Allow the same emergency to alert again after 35 s
              // (covers the 30 s flare window + 5 s margin)
              Future.delayed(const Duration(seconds: 35), () {
                _handledEmgNames.remove(name);
              });

              // Relay it — BLE range is roughly one floor. Without this,
              // an emergency flare simply never reaches anyone more than
              // one hop away (e.g. a different floor of the same
              // building). Gated on the same "first time we've seen this
              // exact string" check above, so this naturally terminates
              // once every reachable device has relayed it once — no
              // hop-count field needed, no relay storm.
              _scheduleEmgRelay(name);

              final payload = name.substring(4);
              final parts = payload.split(':');
              final sender = parts.isNotEmpty ? parts[0] : 'Unknown';
              final reason =
              parts.length > 1 ? parts.sublist(1).join(':') : 'Emergency';
              await NotificationService.showEmergencyNotification(
                sender: sender,
                reason: reason,
              );
            }

            // Signature chunk reassembly — runs on every scan result for
            // this flare (not just the first), since chunks keep arriving
            // for several seconds after the alert itself first appears.
            // Broadcast in the same packet as the flare's own name (see
            // _startFlareSignatureCycle), so `name` doubles as the
            // reassembly key.
            final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
            if (mfgBytes != null && !_flareSigHandledNames.contains(name)) {
              final decodedSig = decodeFlareSigChunk(mfgBytes);
              if (decodedSig != null) {
                final buffer = _pendingFlareSigChunks.putIfAbsent(
                    name, () => _FlareSigBuffer(decodedSig.totalChunks));
                buffer.chunks[decodedSig.chunkIndex] = decodedSig.bytes;
                buffer.lastSeen = DateTime.now();
                if (buffer.isComplete) {
                  _pendingFlareSigChunks.remove(name);
                  await _verifySignedAlert(name, Uint8List.fromList(buffer.reassembled),
                      requireAdmin: false);
                }
              }
              // Drop reassembly buffers we've stopped hearing chunks for —
              // some were missed and the sender's cycle moved on.
              final staleCutoff = DateTime.now().subtract(const Duration(seconds: 20));
              _pendingFlareSigChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));
            }
          }
        }

        if (name.startsWith("EMG_OFF:")) {
          if (!_handledEmgOffNames.contains(name)) {
            _handledEmgOffNames.add(name);
            Future.delayed(const Duration(seconds: 10), () {
              _handledEmgOffNames.remove(name);
            });
            // Relay the cancel too — a device that only relayed the
            // original EMG: and never hears (or relays) the matching
            // EMG_OFF: would leave anyone further down the chain stuck
            // with an alarm that never gets dismissed.
            _scheduleEmgRelay(name);
            // Dismiss the emergency notification on this device
            await NotificationService.cancelEmergencyNotification();
          }
        }

        // Admin Official Alert — same shape as EMG:/EMG_OFF: above, kept
        // as a fully separate block (own dedup sets, own verification
        // call with requireAdmin: true) rather than merged in, since the
        // two tiers' notification handling genuinely diverges (reject vs.
        // downgrade on failed verification — see _verifySignedAlert).
        if (name.startsWith("ADM:")) {
          // Same exact-match fix as EMG: above — a startsWith prefix check
          // here would silently swallow another admin's real alert whenever
          // their truncated username started with ours.
          final myTruncated = myUsername.length > 8 ? myUsername.substring(0, 8) : myUsername;
          final admSender = name.substring(4).split(':').first;
          if (admSender != myTruncated) {
            if (!_handledAdmNames.contains(name)) {
              _handledAdmNames.add(name);
              Future.delayed(const Duration(seconds: 35), () {
                _handledAdmNames.remove(name);
              });
              _scheduleEmgRelay(name); // generic relay helper, not EMG-specific despite the name

              final payload = name.substring(4);
              final parts = payload.split(':');
              final sender = parts.isNotEmpty ? parts[0] : 'Unknown';
              final reason = parts.length > 1 ? parts.sublist(1).join(':') : 'Emergency';
              // Shown immediately, unverified — same fail-open reasoning
              // as a personal flare. Downgraded to a hard rejection (not
              // "Unverified") if the signature/role check below fails.
              await NotificationService.showOfficialAlertNotification(
                sender: sender,
                reason: reason,
              );
            }

            final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
            if (mfgBytes != null && !_flareSigHandledNames.contains(name)) {
              final decodedSig = decodeFlareSigChunk(mfgBytes);
              if (decodedSig != null) {
                final buffer = _pendingFlareSigChunks.putIfAbsent(
                    name, () => _FlareSigBuffer(decodedSig.totalChunks));
                buffer.chunks[decodedSig.chunkIndex] = decodedSig.bytes;
                buffer.lastSeen = DateTime.now();
                if (buffer.isComplete) {
                  _pendingFlareSigChunks.remove(name);
                  await _verifySignedAlert(name, Uint8List.fromList(buffer.reassembled),
                      requireAdmin: true);
                }
              }
              final staleCutoff = DateTime.now().subtract(const Duration(seconds: 20));
              _pendingFlareSigChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));
            }
          }
        }

        if (name.startsWith("ADM_OFF:")) {
          if (!_handledAdmOffNames.contains(name)) {
            _handledAdmOffNames.add(name);
            Future.delayed(const Duration(seconds: 10), () {
              _handledAdmOffNames.remove(name);
            });
            _scheduleEmgRelay(name);
            await NotificationService.cancelEmergencyNotification();
          }
        }
      }
    });

    await _startContinuousScan();

    // Initial count after BLE has had 5 seconds to warm up
    Future.delayed(const Duration(seconds: 5), _updateBleDeviceCount);
    // Then refresh every 30 seconds
    _bleCountTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateBleDeviceCount();
    });
  }

  Future<void> _stopAllAdvertising() async => BlePeripheral.stopAdvertising();
  Future<void> _startContinuousScan() async {
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      continuousUpdates: true,
      withServices: [Guid(HOPS_SERVICE_UUID)], // ← hardware filter
    );
  }

  // ---------- Pairing ----------
  void _startPairingServer(String code) {
    _activePairingCode = code;
    BlePeripheral.stopAdvertising().then((_) {
      _advertiseWithName("HOP:$code:$myUsername", []);
    });
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(const Duration(seconds: 180), () {
      _cleanupPairingServer();
    });
  }

  void _cleanupPairingServer() {
    _pairingTimeout?.cancel();
    if (_activePairingCode != null) {
      _stopAllAdvertising();
      _activePairingCode = null;
    }
  }

  Future<void> _startPairingClient(String code) async {
    await FlutterBluePlus.stopScan();

    final completer = Completer<String?>();
    StreamSubscription<List<ScanResult>>? sub;

    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName;
        if (name.startsWith("HOP:$code:")) {
          final remoteUsername = name.substring("HOP:$code:".length);
          if (!completer.isCompleted) completer.complete(remoteUsername);
        }
      }
    });

    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      withServices: [Guid(HOPS_SERVICE_UUID)], // ← hardware filter
    );

    String? remoteUsername;
    try {
      remoteUsername =
      await completer.future.timeout(const Duration(seconds: 30));
    } catch (_) {}

    await sub.cancel();
    await FlutterBluePlus.stopScan();

    if (remoteUsername == null) {
      _showToastFeedbackAlert(
          "Device not found. Ensure the code is active on the other device.");
      return;
    }

    await _writeContactLogToDatabase(remoteUsername, "Mutual pairing via code");
    await _sendAck(code);
    _showToastFeedbackAlert("Connected with $remoteUsername!");
    await _startContinuousScan();
  }

  Future<void> _sendAck(String code) async {
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName("ACK:$code:$myUsername", []);
    Future.delayed(const Duration(seconds: 5), () {
      if (_activePairingCode == null) {
        _stopAllAdvertising();
      }
    });
  }

  // ---------- Contacts management ----------
  Future<void> _refreshContactsTrayList() async {
    final db = await DatabaseHelper.instance.database;
    // Ordered oldest->newest so the last write into contactThreads below
    // ends up being the most recent message in each thread.
    final maps = await db.query(DatabaseHelper.table, orderBy: '${DatabaseHelper.columnTimestamp} ASC');
    Map<String, Map<String, dynamic>> contactThreads = {};

    // Existing contacts from messages — keyed by peer_id (the conversation
    // partner) so BOTH directions update the preview, not just messages
    // received from them. peer_id is null on rows written before that
    // column existed; for those, fall back to sender_id, which only ever
    // worked for inbound rows anyway (outgoing rows from that era can't be
    // attributed to a peer and are skipped, same as before).
    for (var row in maps) {
      final sender = row[DatabaseHelper.columnSenderId] as String;
      final peerId = row[DatabaseHelper.columnPeerId] as String?;
      final peer = peerId ?? (sender != myUsername ? sender : null);
      if (peer == null || peer == myUsername) continue;

      final isMine = sender == myUsername;
      final text = row[DatabaseHelper.columnMessage] as String;
      contactThreads[peer] = {
        'username': peer,
        'lastMsg': isMine ? 'You: $text' : text,
        'time': 'Nearby'
      };
    }

    // Ensure every added friend appears, even with no messages
    for (final friend in _addedFriends) {
      if (!contactThreads.containsKey(friend)) {
        contactThreads[friend] = {
          'username': friend,
          'lastMsg': 'Connected',
          'time': ''
        };
      }
    }

    // Attach whatever avatar we've cached for each contact — populated the
    // first time you've actually chatted with them (see chat_terminal.dart
    // / HopsChatService.sendProfile), absent until then.
    final profiles = await DatabaseHelper.instance.getAllContactProfiles();
    for (final entry in contactThreads.entries) {
      entry.value['avatarPath'] = profiles[entry.key]?[DatabaseHelper.cpColAvatarPath];
    }

    // Refreshed here too — a contact's seed only ever arrives via the same
    // first-chat exchange that updates avatar/bio, so anything that
    // invalidates one should invalidate the other.
    final seeds = await DatabaseHelper.instance.getAllContactRotatingSeeds();

    setState(() {
      localActiveContacts = contactThreads.values.toList();
      _contactSeeds = seeds;
    });
  }

  Future<void> _writeContactLogToDatabase(String peerName, String text) async {
    final outgoingPayload = {
      DatabaseHelper.columnId: const Uuid().v4(),
      DatabaseHelper.columnMessage: text,
      DatabaseHelper.columnSenderId: peerName,
      DatabaseHelper.columnPeerId: peerName,
      DatabaseHelper.columnIsForMe: 1,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertMessage(outgoingPayload);
    await _refreshContactsTrayList();
  }

  // Shared by both places a contact can be deleted from: the profile card
  // reached via the Contacts list, and the one reached from inside an open
  // chat. _addedFriends previously wasn't cleared here, which meant a
  // friend-request-added contact would silently reappear on the very next
  // refresh (_refreshContactsTrayList re-adds anyone still in that set).
  Future<void> _deleteContact(String peerName) async {
    await DatabaseHelper.instance.deleteConversationWithPeer(peerName);
    await DatabaseHelper.instance.deleteContactProfile(peerName);
    _addedFriends.remove(peerName);
    await _refreshContactsTrayList();
    _showToastFeedbackAlert("Removed $peerName from your contacts.");
  }

  void _showToastFeedbackAlert(String alertMessage) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: theme.colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        content: Text(alertMessage, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  void _executeActiveHandshakeVerification(String code) async {
    String formatted = code.toUpperCase().trim();
    if (!formatted.startsWith("HPS-") || formatted.length != 11) {
      _showToastFeedbackAlert("Invalid format. Use HPS-XXX-YYY.");
      return;
    }
    String rawCode = formatted.replaceAll("HPS-", "").replaceAll("-", "");
    if (rawCode.length != 6) {
      _showToastFeedbackAlert("Code must be 6 alphanumeric characters.");
      return;
    }
    await _startPairingClient(rawCode);
  }

  // ---------- Feature toggling ----------
  void _toggleFeature(int featureId) {
    setState(() {
      if (enabledFeatureIds.contains(featureId)) {
        enabledFeatureIds.remove(featureId);
      } else {
        enabledFeatureIds.add(featureId);
      }
    });
    _saveEnabledFeatures();
  }

  Future<void> _loadEnabledFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('enabledFeatureIds') ?? [];
    setState(() => enabledFeatureIds = ids.map((s) => int.parse(s)).toSet());
  }

  Future<void> _saveEnabledFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('enabledFeatureIds', enabledFeatureIds.map((id) => id.toString()).toList());
  }

  Future<void> _loadFeatureOrderAndPins() async {
    final prefs = await SharedPreferences.getInstance();
    final orderStrings = prefs.getStringList('feature_order') ?? [];
    final pinnedStrings = prefs.getStringList('pinned_feature_ids') ?? [];
    setState(() {
      _featureOrder = orderStrings.map((s) => int.tryParse(s)).whereType<int>().toList();
      _pinnedFeatureIds = pinnedStrings.map((s) => int.tryParse(s)).whereType<int>().toSet();
    });
  }

  Future<void> _saveFeatureOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('feature_order', _featureOrder.map((id) => id.toString()).toList());
  }

  Future<void> _savePinnedFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'pinned_feature_ids', _pinnedFeatureIds.map((id) => id.toString()).toList());
  }

  // Pinned features first (in their relative saved order), then everything
  // else in saved order — features never seen in _featureOrder before
  // (just enabled, or enabled before this feature existed) fall back to
  // their catalog position rather than being silently dropped to the end
  // in an unpredictable order.
  List<FeatureItem> _orderedEnabledFeatures() {
    final enabled = allFeatures.where((f) => enabledFeatureIds.contains(f.id)).toList();
    final orderIndex = <int, int>{
      for (var i = 0; i < _featureOrder.length; i++) _featureOrder[i]: i,
    };
    enabled.sort((a, b) {
      final aPinned = _pinnedFeatureIds.contains(a.id);
      final bPinned = _pinnedFeatureIds.contains(b.id);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      final aIdx = orderIndex[a.id] ?? (1000 + allFeatures.indexOf(a));
      final bIdx = orderIndex[b.id] ?? (1000 + allFeatures.indexOf(b));
      return aIdx.compareTo(bIdx);
    });
    return enabled;
  }

  void _toggleFeaturePin(int featureId) {
    setState(() {
      if (_pinnedFeatureIds.contains(featureId)) {
        _pinnedFeatureIds.remove(featureId);
      } else {
        _pinnedFeatureIds.add(featureId);
      }
    });
    _savePinnedFeatures();
  }

  // Drag-to-reorder — materializes the *current displayed* order into
  // _featureOrder before swapping, so a feature that was only ever
  // sitting at its catalog-order fallback position gets a real, durable
  // position the moment someone actually reorders anything.
  void _reorderFeature(int draggedId, int targetId) {
    if (draggedId == targetId) return;
    final current = _orderedEnabledFeatures().map((f) => f.id).toList();
    final draggedIndex = current.indexOf(draggedId);
    final targetIndex = current.indexOf(targetId);
    if (draggedIndex == -1 || targetIndex == -1) return;
    current.removeAt(draggedIndex);
    current.insert(targetIndex, draggedId);
    setState(() => _featureOrder = current);
    _saveFeatureOrder();
  }

  void _openFeaturePage(FeatureItem feature) {
    if (feature.id == 2) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WatchMePage(
            radarStream: radarStream,
            friendUsernames: friendUsernames,
            watchingBuddies: _watchingBuddies,
            contactSeeds: _contactSeeds,
            watchingBuddiesStream: watchingBuddiesStream,
            pendingWatchStream: pendingWatchStream,
            onSendWatchRequest: sendWatchRequest,
            onAcceptWatchRequest: acceptWatchRequestFromCard,
            onDeclineWatchRequest: declineWatchRequestFromCard,
            onStopWatching: stopWatchingBuddy,
            onClearAll: clearAllWatchState,
          ),
        ),
      );
    } else if (feature.id == 5) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VibeCheckPage(
            radarStream: radarStream,
            onAdvertiseVibeTag: _advertiseVibeTag,
          ),
        ),
      );
    } else if (feature.id == 9) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const TaskTrackerPage()),
      );
    } else if (feature.id == 11) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => HopsSharePage(myUsername: myUsername)),
      );
    } else if (feature.pageBuilder != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => feature.pageBuilder!()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("${feature.name} page not built yet")),
      );
    }
  }

  // ---------- UI (fully dynamic theme) ----------
  PreferredSizeWidget _buildSharedCustomAppBar(String title) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
      title: Row(
        children: [
          Icon(Icons.bluetooth_audio, color: colors.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontSize: 20,
                color: colors.primary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _bleMeshColor(_nearbyBleCount).withOpacity(0.12),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing color dot
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _bleMeshColor(_nearbyBleCount),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _bleMeshColor(_nearbyBleCount).withOpacity(0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$_nearbyBleCount Nearby',
                style: TextStyle(
                  color: _bleMeshColor(_nearbyBleCount),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const HopsProfileScreen()),
          ).then((_) {
            _refreshContactsTrayList();
            _loadCurrentIdentityMetrics();
          }),
          child: Container(
            margin: const EdgeInsets.only(right: 16),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: colors.primary,
              backgroundImage: _myAvatarPath != null
                  ? FileImage(File(_myAvatarPath!))
                  : null,
              child: _myAvatarPath == null
                  ? const Icon(Icons.cruelty_free, size: 18, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    // Messages tab is self-contained — owns its own BT discovery and session mgmt.
    final List<Widget> tabs = [
      RadarScreen(
        radarStream: radarStream,
        onSendFriendRequest: sendFriendRequest,
        pendingRequests: pendingRequests,
        onAcceptRequest: acceptRequest,
        onDeclineRequest: declineRequest,
        friendUsernames: friendUsernames,
        contactSeeds: _contactSeeds,
        onActivateFlare: (String reason) => _broadcastEmergencyFlare(reason),
        onActivateOfficialAlert: (String reason) => _broadcastOfficialAlert(reason),
        isAdmin: _isAdmin,
        onRescan: () {
          FlutterBluePlus.stopScan();
          _startContinuousScan();
        },
        nearbyBleCount: _nearbyBleCount,
        autoOpenFlareDialog: _pendingFlareShortcut,
        onAutoFlareDialogConsumed: () => _pendingFlareShortcut = false,
        isDiscoverable: _isDiscoverable,
        onSetDiscoverable: _setDiscoverable,
      ),
      _buildContactsTab(),             // index 1 — unchanged radar contacts
      CommunityChat(
        radarStream: radarStream,
        onSendMessage: _advertiseCommunityMessage,
        myUsername: myUsername,
        mySeed: _myRotatingSeed,
        contactSeeds: _contactSeeds,
      ), // index 2 — NEW: BT peer chat
      _buildFeaturesTab(),             // index 3
      _buildMyFeaturesTab(),           // index 4
    ];

    return Scaffold(
      // Lets the body's own background (and the HopsBackgroundPattern on
      // it) show through the margin around the floating nav pill below,
      // instead of the pill sitting flush against the screen edges like a
      // flat bar.
      extendBody: true,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        children: tabs,
      ),
      floatingActionButton: _currentIndex == 1
          ? Padding(
        padding: const EdgeInsets.only(bottom: 12.0),
        child: FloatingActionButton(
          backgroundColor: colors.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          onPressed: () => _showAddContactModalSheet(context),
          child: const Icon(Icons.add, size: 28),
        ),
      )
          : null,
      bottomNavigationBar: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          // Default layoutBuilder stacks children with Alignment.center,
          // and the Stack sizes itself to whatever height the Scaffold
          // hands the bottomNavigationBar slot — often much taller than
          // either child actually needs. Centering within that meant the
          // small hidden-state arrow landed vertically mid-screen instead
          // of hugging the bottom edge. Pinning alignment to bottomCenter
          // here fixes both children regardless of that slot's height.
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: _navBarHidden
              ? _buildHiddenNavIndicator(colors)
              : _buildFloatingNavBar(colors),
        ),
      ),
    );
  }

  // The pill itself — swiping down on it tucks it away (see
  // _buildHiddenNavIndicator for how it comes back). The small down-arrow
  // riding just above it is the visual hint that this is possible at all —
  // nothing about a normal-looking nav bar otherwise suggests it's
  // swipeable.
  final GlobalKey _navPillKey = GlobalKey();

  Widget _buildFloatingNavBar(ColorScheme colors) {
    // Reports this widget's actual rendered height once it's laid out, so
    // anything positioned above it elsewhere (Community Chat's input bar)
    // can clear it exactly rather than guessing — see navBarPillHeightNotifier
    // in main.dart. Re-measures every build (font-scale changes, badge
    // counts wrapping to a second line, etc. can all change this height).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final height = _navPillKey.currentContext?.size?.height;
      if (height != null && height > 0 && navBarPillHeightNotifier.value != height) {
        navBarPillHeightNotifier.value = height;
      }
    });
    return Padding(
      key: _navPillKey,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 200) {
            setState(() => _navBarHidden = true);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Its own tap target (separate from the drag-anywhere-on-the-
            // pill gesture above) — previously this arrow just sat there
            // implying "tap me to hide" without actually responding to a
            // tap, only a swipe.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _navBarHidden = true),
              // Was a bare Icon with no background, sized/opacity so low it
              // read as barely-there — inconsistent with the hidden-state
              // up-arrow below, which sits in its own filled pill (see
              // _buildHiddenNavIndicator), and easy to miss as a tap target
              // at all. Matching that same treatment here makes both ends
              // of the show/hide gesture look like one consistent control.
              child: Container(
                width: 40,
                height: 22,
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(100),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(Icons.keyboard_arrow_down, size: 18, color: colors.primary),
              ),
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildNavItem(0, Icons.home_outlined, Icons.home, "Home", badgeCount: pendingRequests.length),
                  _buildNavItem(1, Icons.people_outline,  Icons.people,    "Contacts"),
                  _buildNavItem(2, Icons.campaign_outlined, Icons.campaign, "Community"),
                  _buildNavItem(3, Icons.grid_view_outlined, Icons.grid_view, "Features"),
                  _buildNavItem(4, Icons.star_outline,    Icons.star,      "My Features"),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Stand-in shown once the pill's been swiped away — tap it, or swipe up
  // on it, to bring the full nav bar back. Deliberately NOT wrapped in a
  // Center/Align — either greedily expands to fill whatever height the
  // Scaffold hands the bottomNavigationBar slot and then centers this tiny
  // widget within that (often much taller) box, which is what put the
  // arrow near the middle of the screen instead of the bottom. The
  // AnimatedSwitcher's own Stack (bottomCenter-aligned, see above) is what
  // actually positions this now.
  Widget _buildHiddenNavIndicator(ColorScheme colors) {
    return Padding(
      key: const ValueKey('navBarHidden'),
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _navBarHidden = false),
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -200) {
            setState(() => _navBarHidden = false);
          }
        },
        child: Container(
          width: 56,
          height: 26,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(100),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(Icons.keyboard_arrow_up, color: colors.primary, size: 20),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label, {int badgeCount = 0}) {
    bool isSelected = _currentIndex == index;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return GestureDetector(
      // Animate the PageView itself rather than setState-ing _currentIndex
      // directly — onPageChanged (wired to the PageView above) is what
      // actually updates _currentIndex now, so a nav tap and a swipe both
      // go through the exact same code path instead of two separate ones
      // that could drift out of sync with each other.
      onTap: () => _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(isSelected ? activeIcon : icon,
                    color: isSelected ? Colors.white : colors.primary.withOpacity(0.6)),
                if (badgeCount > 0)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(100),
                        border: Border.all(color: theme.scaffoldBackgroundColor, width: 1.5),
                      ),
                      child: Text(
                        badgeCount > 9 ? '9+' : '$badgeCount',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold, height: 1.3),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : colors.primary.withOpacity(0.6),
                ),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsTab() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Contacts"),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(child: localActiveContacts.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cruelty_free, size: 64, color: colors.primary.withOpacity(0.18)),
                    const SizedBox(height: 16),
                    Text(
                      "No contacts yet.\nEnter a pairing code to connect.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurface.withOpacity(0.5), height: 1.4),
                    ),
                  ],
                ),
              )
            : Column(
          children: [
            // Only worth the extra chrome once there's actually enough
            // contacts that scrolling to find one is annoying.
            if (localActiveContacts.length > 4)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _contactSearchController,
                  onChanged: (value) => setState(() => _contactSearchQuery = value),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: "Search contacts…",
                    hintStyle: TextStyle(color: colors.onSurface.withOpacity(0.4)),
                    prefixIcon: Icon(Icons.search, size: 20, color: colors.onSurface.withOpacity(0.5)),
                    suffixIcon: _contactSearchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.close, size: 18, color: colors.onSurface.withOpacity(0.5)),
                            onPressed: () => setState(() {
                              _contactSearchController.clear();
                              _contactSearchQuery = '';
                            }),
                          ),
                    filled: true,
                    fillColor: colors.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(100),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: _filteredContacts.isEmpty
                  ? Center(
                      child: Text(
                        "No contacts match \"$_contactSearchQuery\".",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurface.withOpacity(0.5)),
                      ),
                    )
                  : ListView.builder(
          // Bottom clearance for the floating nav pill — the Scaffold uses
          // extendBody: true so the body draws underneath it, and without
          // this the last one or two contacts end up permanently hidden
          // behind the pill with no way to scroll past it.
          padding: EdgeInsets.fromLTRB(0, 8, 0, kFloatingNavClearance),
          itemCount: _filteredContacts.length,
          itemBuilder: (context, index) {
            final contact = _filteredContacts[index];
            final username = contact['username'] as String;
            final avatarPath = contact['avatarPath'] as String?;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: HopsCard(
              padding: EdgeInsets.zero,
              radius: 18,
              child: ListTile(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => IndividualChatTerminalView(
                      peerName: username,
                      onDeleteContact: _deleteContact,
                    ),
                  ),
                ).then((_) => _refreshContactsTrayList()),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                // Own tap target, separate from the row's — tapping the
                // circle specifically opens the profile card instead of
                // the chat. No longer shows the username as text; just
                // the photo, or the default person icon if none is
                // cached yet (only known once you've chatted with them).
                leading: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ContactProfileScreen(
                        peerUsername: username,
                        onDeleteContact: _deleteContact,
                      ),
                    ),
                  ).then((_) => _refreshContactsTrayList()),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: colors.primary.withOpacity(0.1),
                    backgroundImage: avatarPath != null ? FileImage(File(avatarPath)) : null,
                    child: avatarPath == null
                        ? Icon(Icons.cruelty_free, color: colors.primary)
                        : null,
                  ),
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        username,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: colors.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      contact['time'] as String,
                      style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.4)),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    contact['lastMsg'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.onSurface.withOpacity(0.6)),
                  ),
                ),
              ),
              ),
            );
          },
        ),
            ),
          ],
        )),
      ),
    );
  }

  void _showAddContactModalSheet(BuildContext context) {
    final theme = Theme.of(context);      // ← here
    final colors = theme.colorScheme;     // ← here
    // Kept separate from the sheet's own (shadowed) `context` below — that
    // one belongs to the bottom sheet route and is mid-removal by the time
    // Navigator.pop() runs inside an onPressed callback, so pushing a new
    // route off of it (the pairing-code dialog, the QR scanner) was racing
    // the sheet's own close animation. Pushing off this outer, always-
    // mounted screen context instead is what actually fixed the pairing
    // code dialog rendering as a blank dimmed screen.
    final screenContext = context;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28))),
      builder: (context) {
        return StatefulBuilder(builder: (BuildContext context, StateSetter setModalState) {
          return Padding(
            padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: colors.onSurface.withOpacity(0.2), borderRadius: BorderRadius.circular(100)))),
                const SizedBox(height: 20),
                Text("Add Peer Node", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colors.primary)),
                const SizedBox(height: 6),
                Text("Enter the 6‑character pairing code shown on your classmate's device.", style: TextStyle(fontSize: 13, color: colors.onSurface.withOpacity(0.6))),
                const SizedBox(height: 24),
                Text("ENTER PAIRING CODE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: colors.primary, letterSpacing: 1.2)),
                const SizedBox(height: 6),
                TextField(
                  controller: _manualIdController,
                  autofocus: true,
                  inputFormatters: [HopIdInputFormatter()],
                  style: const TextStyle(fontSize: 14, fontFamily: 'monospace', letterSpacing: 1.2),
                  decoration: InputDecoration(
                    hintText: "HPS-XXX-YYY",
                    prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                    filled: true,
                    fillColor: colors.surfaceContainerHighest,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: colors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100))),
                    onPressed: () {
                      if (_manualIdController.text.length == 11) {
                        _executeActiveHandshakeVerification(_manualIdController.text.trim());
                        _manualIdController.clear();
                        Navigator.pop(context);
                      } else {
                        _showToastFeedbackAlert("Code must be fully typed (HPS-XXX-YYY)");
                      }
                    },
                    child: const Text("Connect", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 12),
                Divider(color: colors.surfaceContainerHighest),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: Icon(Icons.confirmation_number_outlined, size: 18, color: colors.tertiaryContainer),
                    label: Text("Generate My Pairing Code", style: TextStyle(color: colors.tertiaryContainer, fontWeight: FontWeight.bold, fontSize: 13)),
                    onPressed: () {
                      Navigator.pop(context);
                      // Popping the bottom sheet and pushing a new dialog
                      // route in the very same frame used to hit a Flutter
                      // rendering assertion ('_owner != null': is not true)
                      // — the sheet's closing-route cleanup and the
                      // dialog's Overlay insertion collided mid-transition.
                      // Waiting for the pop's frame to fully finish first
                      // avoids the race.
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _showTokenGeneratorDialog(screenContext);
                      });
                    },
                  ),
                )
              ],
            ),
          );
        });
      },
    );
  }

  void _showTokenGeneratorDialog(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    showDialog(context: context, builder: (context) => TokenGeneratorWorkspace(
      onCodeGenerated: (code) {
        _startPairingServer(code);
      },
    )).then((_) => _refreshContactsTrayList());
  }

  Widget _buildFeaturesTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Features"),
      body: HopsBackgroundPattern(child: ListView.builder(
        // Bottom clearance for the floating nav pill — see the identical
        // fix on the Contacts tab above. Without it, the last card or two
        // stays hidden behind the pill even once fully scrolled, which is
        // what made expanding the first few look like "nothing scrolls."
        padding: const EdgeInsets.fromLTRB(16, 16, 16, kFloatingNavClearance),
        itemCount: allFeatures.length,
        itemBuilder: (context, index) {
          final feature = allFeatures[index];
          final isEnabled = enabledFeatureIds.contains(feature.id);
          return _buildFeatureCard(feature, isEnabled);
        },
      )),
    );
  }

  Widget _buildFeatureCard(FeatureItem feature, bool isEnabled) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Inherits shape/color/elevation from the theme's CardTheme now
    // (see app_theme.dart) rather than overriding all three here — was a
    // flat primary.withOpacity(0.4) fill with elevation: 0, i.e. no
    // shadow at all, one of the "dull, flat" patterns this whole pass is
    // about getting rid of.
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      // ExpansionTile draws a top+bottom divider line around its expanded
      // children by default (its shape/collapsedShape fall back to the
      // ambient Theme's dividerColor) — pointless here since the Card
      // already draws its own boundary around the whole tile, so it just
      // showed up as a stray line above and below the long description.
      // Same fix _buildExpandableOptionTree used to use for this.
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
        leading: Icon(feature.icon, color: colors.primary, size: 28),
        title: Text(
          feature.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: colors.primary,   // ★ use the theme primary colour
          ),
        ),
        subtitle: Text(
          feature.shortDesc,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.6)),
          // Was maxLines: 1 — several of the rewritten shortDesc strings
          // don't fit on one line at this width/font size and were
          // rendering as a truncated "…" instead of the actual sentence.
          maxLines: 2,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              feature.longDesc,
              style: TextStyle(fontSize: 13, color: colors.onSurface.withOpacity(0.85)),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 12),
              child: ElevatedButton.icon(
                icon: Icon(
                  isEnabled ? Icons.check_circle : Icons.add_circle_outline,
                  size: 18,
                ),
                label: Text(isEnabled ? "Remove" : "Add"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isEnabled
                      ? colors.tertiaryContainer.withOpacity(0.3)
                      : colors.primary,
                  foregroundColor: isEnabled ? colors.primary : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                onPressed: () => _toggleFeature(feature.id),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

  // --------------- My Features tab ---------------
  // Tiles are long-press-draggable onto each other to reorder (own drag
  // handle isn't needed — the whole tile already has a tap action, so
  // long-press is free to mean "start reordering" without conflicting
  // with it), and pinnable via the small pin icon so favorites stay put
  // at the top regardless of what order they were enabled in.
  Widget _buildMyFeaturesTab() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final orderedFeatures = _orderedEnabledFeatures();

    return Scaffold(
      appBar: AppBar(
        title: Text("My Features",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
        actions: [
          TextButton.icon(
            icon: Icon(Icons.add_circle_outline, size: 18, color: colors.primary),
            label: Text("Manage", style: TextStyle(color: colors.primary)),
            onPressed: () => setState(() => _currentIndex = 3),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(child: orderedFeatures.isEmpty
            ? Center(
          child: Text(
            "No features added yet.\nGo to 'Features' to enable some!",
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurface.withOpacity(0.5)),
          ),
        )
            : GridView.builder(
          // Same floating-nav-pill clearance as Features/Contacts.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, kFloatingNavClearance),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.9,
          ),
          itemCount: orderedFeatures.length,
          itemBuilder: (context, index) {
            final feature = orderedFeatures[index];
            final isPinned = _pinnedFeatureIds.contains(feature.id);

            final tile = Card(
              // Zero margin specifically here (unlike the theme default)
              // — grid spacing is already handled by the GridView's own
              // crossAxisSpacing/mainAxisSpacing, so the theme's default
              // card margin would just add uneven extra gaps on top of it.
              margin: EdgeInsets.zero,
              child: Stack(
                // Stack aligns to top-left by default — without this, the
                // icon+label Column (an unpositioned Stack child) stopped
                // being centered the moment the pin overlay turned this
                // into a Stack, and just sat top-left instead, which read
                // as the pin "pushing everything left".
                alignment: Alignment.center,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(feature.icon, size: 36, color: colors.primary),
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          feature.name,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: colors.primary,
                          ),
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => _toggleFeaturePin(feature.id),
                      child: Padding(
                        // Bigger tap target than the icon itself so pinning
                        // doesn't require pixel-perfect precision.
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                          size: 16,
                          color: isPinned
                              ? colors.primary
                              : colors.primary.withOpacity(0.35),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );

            return DragTarget<int>(
              onWillAcceptWithDetails: (details) => details.data != feature.id,
              onAcceptWithDetails: (details) => _reorderFeature(details.data, feature.id),
              builder: (context, candidateData, rejectedData) {
                final isDragTarget = candidateData.isNotEmpty;
                return LongPressDraggable<int>(
                  data: feature.id,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: Opacity(opacity: 0.85, child: tile),
                    ),
                  ),
                  childWhenDragging: Opacity(opacity: 0.3, child: tile),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: isDragTarget
                          ? Border.all(color: colors.primary, width: 2)
                          : null,
                    ),
                    child: GestureDetector(
                      onTap: () => _openFeaturePage(feature),
                      child: tile,
                    ),
                  ),
                );
              },
            );
          },
        )),
      ),
    );
  }
}

// Buffers Emergency Flare signature chunks for one in-flight verification
// until every piece has arrived — see _startFlareSignatureCycle /
// _verifyFlareSignature above. Mirrors community_chat.dart's _ChunkBuffer.
class _FlareSigBuffer {
  final int totalChunks;
  final Map<int, List<int>> chunks = {};
  DateTime lastSeen;
  _FlareSigBuffer(this.totalChunks) : lastSeen = DateTime.now();
  bool get isComplete => chunks.length >= totalChunks;
  List<int> get reassembled =>
      [for (var i = 0; i < totalChunks; i++) ...?chunks[i]];
}