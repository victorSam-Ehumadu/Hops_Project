// hops_app.dart
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypton/crypton.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:client/main.dart'
    show
        shortcutNotifier,
        nearbyConnectionsSessionCount,
        chatPingRequest,
        navBarPillHeightNotifier,
        bleDirectMessageOutbox,
        bleDirectMessageInbox,
        BleDirectMessage;
import 'package:client/services/bluetooth_permissions.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/services/bluetooth_name_guard.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/utils/hop_id_formatter.dart';
import 'package:client/views/radar_screen.dart';
import 'package:client/views/chat_terminal.dart';
import 'package:client/views/contact_profile_screen.dart';
import 'package:client/services/hops_engine.dart' show kHopsBotUsername;
import 'package:client/widgets/hops_bot_avatar.dart';
import 'package:client/views/token_generator.dart';
import 'package:client/views/profile_screen.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/views/account_management_screen.dart' show wipeLocalIdentityAndReturnToGatekeeper;
import 'package:client/models/feature_item.dart';
import 'package:client/views/vibe_check_page.dart';
import 'package:client/views/study_bunny_finder_page.dart';
import 'package:client/views/lost_found_board_page.dart';
import 'package:client/views/watch_me_page.dart';
import 'package:client/views/task_tracker_page.dart';
import 'package:client/views/hops_share_page.dart';
import 'package:client/views/hops_shop_page.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/avatar_frames.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/services/vibe_report_store.dart';
import 'package:client/services/study_bunny_store.dart';
import 'package:client/services/lost_found_store.dart';
import 'package:client/services/sos_service.dart';
import 'package:client/services/avatar_path_notifier.dart';
import 'package:client/services/accessibility_prefs.dart';
import 'package:client/services/hops_constants.dart';
import 'package:flutter/services.dart';
import 'package:client/views/community_alerts.dart';
import 'package:client/views/notifications_page.dart';
import 'package:client/utils/report_content.dart' show flushPendingReports;
import 'package:client/utils/mesh_crypto.dart'
    show deriveSharedMeshKey, sealDirectMessage, openDirectMessage;
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/widgets/hops_card.dart';

class HopsApp extends StatefulWidget {
  const HopsApp({super.key});
  @override
  State<HopsApp> createState() => _HopsAppState();
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

  bool _isFlareActive = false;
  Timer? _flareCancelTimer;
  Timer? _scanRestartTimer;

  // Swiping down on the floating bottom nav pill tucks it off-screen (more
  // room to read, e.g. a long Community Alerts thread) — a small up-arrow
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
  // _startTaskReminderCheck. Keyed "$taskId:$stage" rather than just
  // task id, since one task can now fire up to four separate reminders
  // (a day before, 2 hours before, 1 hour before, and at the time) —
  // a per-task-only set would let the first stage's notification block
  // every later one for that same task.
  Timer? _taskReminderTimer;
  final Set<String> _remindedTaskStages = {};

  // Periodic "did anything about my identity change remotely" check —
  // there's no push-notification infrastructure in this app, so this is
  // a pull-based stand-in: a device gets notified if its own role just
  // became 'admin' (granted out-of-band, see
  // supabase/migrations/0008_admin_moderation.sql), or force-logged-out
  // if it's been banned. See _syncIdentityStatus.
  Timer? _identitySyncTimer;

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
  // and _advertisePresenceBeacon/_setDiscoverable below.
  //
  // Timed rather than a plain toggle: this broadcasts your real username
  // to everyone in Bluetooth range, and a switch someone can forget to flip
  // back off is exactly the kind of thing that stays on for the rest of
  // the day without anyone meaning it to. It now turns itself off
  // _discoverableAutoOffDuration after being switched on, same idea as a
  // screen timeout.
  //
  // No longer persisted to SharedPreferences across app restarts — it used
  // to be, specifically so a toggle survived a relaunch, but that's now
  // the wrong default: someone who turns it on then force-closes the app
  // seconds later would come back to it silently still broadcasting,
  // having outlived the very timer meant to prevent that. Discoverable
  // mode always starts off on a cold launch.
  bool _isDiscoverable = false;
  Timer? _discoverableAutoOffTimer;
  static const Duration _discoverableAutoOffDuration = Duration(seconds: 10);

  // This account's role, refreshed at every sign-in (see
  // root_gatekeeper.dart) and by the periodic identity-sync poll — drives
  // the "Admin" badge on the profile screen. Broadcasting an Official
  // Alert itself no longer happens from this app at all (moved to the
  // separate Admin app — see lib/main_admin.dart /
  // lib/services/official_alert_service.dart); this device only ever
  // *receives* ADM:/ADM_OFF: broadcasts from an admin's device, same as
  // any other student's.
  String _myRole = 'student';

  // Unread count for the Notifications bell on the Contacts tab (see
  // _buildNotificationsBellButton) — refreshed alongside role/ban status
  // by the same _syncIdentityStatus poll rather than a separate round trip,
  // since get_my_status already returns it (0010_notifications_and_logging.sql).
  int _unreadNotifications = 0;

  // Dedup sets for *receiving* Official Alerts (ADM:/ADM_OFF:) — every
  // student's device still needs these regardless of its own role, since
  // seeing an admin's broadcast is not admin-gated, only sending one is.
  final Set<String> _handledAdmNames = {};
  final Set<String> _handledAdmOffNames = {};

  String? _myAvatarPath;

  String _adUser(String username) =>
      username.length > 9 ? username.substring(0, 9) : username;

  DateTime _lastRadarPush = DateTime(2000);   // force immediate first push

  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  bool _bleInitialized = false;

  String? _activePairingCode;
  Timer? _pairingTimeout;
  // True for the duration of _startPairingClient — the code-*entering*
  // side of a pairing handshake, as opposed to _activePairingCode above
  // (the code-*generating*/hosting side). _updateBleDeviceCount and
  // _scanRestartTimer already skip their own stop/restart scan cycles
  // while _activePairingCode is set, so the host never misses the
  // incoming ACK; the client side had no matching guard, so a periodic
  // scan cycle landing mid-handshake could silently make the client miss
  // the host's HOP: advertisement (or the host miss the client's ACK, if
  // it lands during the client's brief resumed-scan window) — a plausible
  // cause of "only one side ended up with the new contact."
  bool _pairingClientActive = false;

  int _nearbyBleCount = 0;
  Timer? _bleCountTimer;

  // 1:1 direct-message-over-BLE state (RFCOMM fallback — see
  // _broadcastDirectMessage / _handleDirectMessageChunk). Reuses
  // _FlareSigBuffer's shape for reassembly, same as the watch-seed buffer.
  int _directMsgCounter = 0;
  Timer? _directMsgCycleTimer;
  final Map<String, _FlareSigBuffer> _pendingDirectMsgChunks = {};
  final Set<String> _handledDirectMsgKeys = {};

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
  // Dedup for fully-reassembled Lost & Found posts (keyed by postId — see
  // _pendingLnfChunks below for the in-progress reassembly buffers) AND
  // for LNR: resolutions (keyed by the full "LNR:<postId>" string, which
  // can never collide with a bare postId). Also gates relay in both cases.
  // "I'm interested" (SBI:) taps addressed to this device's own active
  // study tag, deduped for a few seconds after each one is processed. An
  // SBI: advertisement stays on-air for _sendStudyInterest's whole 5-second
  // window, and the always-on scanner reports the SAME advertisement many
  // times over that window — without this, one tap fired a notification
  // (and an interest-count bump) once per scan hit instead of once per
  // tap. Deliberately time-bounded rather than a permanent dedup set: a
  // later, genuinely new tap on the same tag (by the same or a different
  // person) should still count.
  final Set<String> _recentSbiIds = {};
  final Set<String> _handledLnfNames = {};
  // In-progress Lost & Found chunk reassembly, keyed by postId — mirrors
  // _pendingFlareSigChunks' shape for Emergency Flare signature chunks.
  final Map<String, _LnfBuffer> _pendingLnfChunks = {};
  // Incoming CHT: pings, keyed by SENDER rather than by the full
  // advertisement string, and held for minutes rather than seconds.
  //
  // The old form keyed on the whole "CHT:<tag>:<sender>" name with a 5s
  // window, which covered only the 3s the sender spends re-advertising a
  // single ping. It did nothing about the real source of the noise: the
  // chat screen fires a ping for every message that can't be delivered,
  // so typing five messages to an offline peer notified them five times
  // with the same "Wants to chat" alert. The message is identical each
  // time and says nothing new, so one is enough for a good while.
  final Map<String, DateTime> _lastChatPingNotifiedAt = {};
  static const Duration _kChatPingNotifyCooldown = Duration(minutes: 2);

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
  final Set<String> _addedFriends = {};
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

    // Restores badges persisted from a previous run — a notification that
    // arrived while the app was closed should still have somewhere to
    // point once it's reopened.
    UnreadTracker.instance.load();
    // Same reason: reports heard before the app was last closed should
    // still be on the list (within their lifetime) when it reopens.
    VibeReportStore.instance.load();
    CosmeticPrefs.instance.load();
    AccessibilityPrefs.instance.load();
    _loadCurrentIdentityMetrics();
    // Also reload on every avatar_path write, from ANYWHERE — without this,
    // the app-bar avatar bubble (visible on every tab, including Contacts)
    // only ever refreshed right after its own Profile-screen navigation
    // returned, so an avatar changed via the Character Creator or Hops
    // Shop (reached some other way) never updated it until the app was
    // restarted. Same fix radar_screen.dart and profile_screen.dart
    // already have — see avatar_path_notifier.dart's header comment.
    avatarPathRevision.addListener(_loadCurrentIdentityMetrics);
    _captureOriginalBluetoothName();
    _loadEnabledFeatures();
    _loadFeatureOrderAndPins();
    _loadWatchState();
    // No _loadDiscoverableState() call anymore — discoverable mode is no
    // longer restored from a previous session. See _isDiscoverable's own
    // comment for why: it now always starts off, and a timer is what turns
    // it off again, not app-restart amnesia.
    _checkPermissionsAndStartBLE();
    _refreshContactsTrayList();
    _maybeShowHelpHint();

    // Best-effort, fire-and-forget — see key_directory.dart. This is what
    // lets Emergency Flare signatures be verified fully offline later,
    // as long as a sync happened at some point while online.
    KeyDirectory.sync();
    _keyDirectorySyncTimer = Timer.periodic(const Duration(minutes: 30), (_) => KeyDirectory.sync());

    _startTaskReminderCheck();
    // Was 3 minutes — a ban (or promotion) could sit unreflected on a
    // signed-in device for up to that long. Shortened to close that gap;
    // still a poll, not a push (see the field comment above), but a much
    // tighter one. Also fired again on every foreground (see
    // _handleAppForegrounded) so reopening the app after being away checks
    // immediately rather than waiting out the rest of this interval.
    _identitySyncTimer = Timer.periodic(const Duration(seconds: 30), (_) => _syncIdentityStatus());
    _syncIdentityStatus(); // also run once immediately rather than waiting for the first interval

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
    //
    // Was 4 minutes — shortened for genuinely noisy/high-density venues
    // (packed room, lots of ambient BLE), where the scan stall this guards
    // against happens more often, not less; capping the *maximum* time
    // spent silently stalled at 90s (rather than 4 minutes) matters more
    // than the modest extra battery/CPU cost of restarting scan more
    // often — restarting a scan is a cheap OS call, not a heavy operation.
    _scanRestartTimer = Timer.periodic(const Duration(seconds: 90), (_) async {
      if (nearbyConnectionsSessionCount.value > 0) return;
      if (_activePairingCode != null || _pairingClientActive) return;
      await FlutterBluePlus.stopScan();
      await _startContinuousScan();
    });

    _diagTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      debugPrint('📡 [DIAG] BLE scan: $_totalScanResults total packets, '
          '${_uniqueHopsDevices.length} unique Hops devices in last 5s');
      _totalScanResults = 0;
      _uniqueHopsDevices.clear();
    });

    WidgetsBinding.instance.addObserver(this);
    nearbyConnectionsSessionCount.addListener(_onNearbyConnectionsSessionCountChanged);
    chatPingRequest.addListener(_onChatPingRequested);
    bleDirectMessageOutbox.addListener(_onBleDirectMessageRequested);
    shortcutNotifier.addListener(_onShortcutTriggered);
    // Cold start: the app-icon shortcut may have already set this before
    // HopsApp even existed (app launched fresh via a shortcut tap) — the
    // listener above only catches taps that happen *while* HopsApp is
    // already mounted (warm start).
    if (shortcutNotifier.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onShortcutTriggered());
    }
    // Silent SOS (Quick Settings tile) — same
    // cold/warm split as shortcutNotifier just above, see
    // services/sos_service.dart's header comment for the native side.
    sosTriggeredNotifier.addListener(_onSosTriggered);
    if (sosTriggeredNotifier.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onSosTriggered());
    }
  }

  // ---------- Emergency Flare confirmation ----------
  //
  // Lives here, on HopsApp itself, rather than on the Radar screen where
  // the old red app-bar button used to own it. Two reasons:
  //
  //   1. There is no in-app flare button any more (see radar_screen.dart)
  //      — every remaining trigger is external (Quick Settings tile,
  //      app-icon shortcut), so neither has a natural home on one
  //      particular tab.
  //   2. HopsApp is the MaterialApp's `home`, so `Navigator.of(context)`
  //      here resolves to the ROOT navigator. Pushing the dialog off this
  //      context puts it above every pushed route — Wordle, a chat, the
  //      Shop, Settings — so the prompt genuinely appears on whatever
  //      screen you're already on. That's the whole point: this used to
  //      jump the PageView to Home first, which both yanked you out of
  //      what you were doing and (in an emergency) wasted the seconds it
  //      took to notice the screen had changed under you.
  //
  // The confirmation itself is deliberately NOT skippable from any of
  // these paths — see HopsSosTileService.kt's header comment.

  // Guards against stacking a second copy of the dialog on top of the
  // first: a second trigger while the prompt is already up (an easy thing
  // to do — you're panicking and tapping the tile again) would otherwise
  // leave two dialogs to dismiss, with only the top one visible.
  bool _flareDialogOpen = false;

  void _showFlareConfirmDialog() {
    if (!mounted || _flareDialogOpen) return;
    _flareDialogOpen = true;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Activate Emergency Flare?"),
        content: const Text(
            "This will alert all nearby Hops users. Use only in real emergencies."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _showFlareReasonDialog();
            },
            child: const Text("NEXT",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      // Cleared however the dialog closes — button, back gesture, or
      // barrier tap — so a cancelled prompt can always be reopened.
    ).whenComplete(() => _flareDialogOpen = false);
  }

  void _showFlareReasonDialog() {
    final reasonController = TextEditingController();
    _flareDialogOpen = true;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("What is the emergency?"),
        content: TextField(
          controller: reasonController,
          autofocus: true,
          maxLength: 25,
          decoration: const InputDecoration(
            hintText: "e.g., Fire in Lab 3",
          ),
          onSubmitted: (_) {
            final reason = reasonController.text.trim();
            if (reason.isEmpty) return;
            Navigator.pop(ctx);
            _broadcastEmergencyFlare(reason);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              final reason = reasonController.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx);
              _broadcastEmergencyFlare(reason);
            },
            child: const Text("ACTIVATE",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).whenComplete(() {
      _flareDialogOpen = false;
      reasonController.dispose();
    });
  }

  void _onSosTriggered() {
    if (!sosTriggeredNotifier.value) return;
    sosTriggeredNotifier.value = false;
    // No page change at all — see _showFlareConfirmDialog's comment. The
    // previous version jumped the PageView to Home (and before that,
    // desynced the nav pill from the actual page by only setting
    // _currentIndex), both of which are now unnecessary: the dialog
    // renders over whatever route is on top.
    _showFlareConfirmDialog();
  }

  // Handles a tap on any of the app-icon shortcuts registered in
  // main.dart. Consumes (clears) the notifier immediately so this only
  // ever fires once per tap, not repeatedly on every future rebuild.
  void _onShortcutTriggered() {
    final type = shortcutNotifier.value;
    if (type == null) return;
    shortcutNotifier.value = null;
    switch (type) {
      case 'community_alerts':
        // See _onSosTriggered's comment — setState alone on _currentIndex
        // never moves the actual PageView.
        if (_pageController.hasClients) {
          _pageController.animateToPage(
            2,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        } else {
          setState(() => _currentIndex = 2);
        }
        break;
      case 'emergency_flare':
        // Opens the same confirm-then-reason dialog every other flare
        // trigger uses, in place, without changing tabs — a shortcut
        // skipping straight past that friction would undermine the whole
        // reason it's there.
        _showFlareConfirmDialog();
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
    if (_watchingBuddies.isEmpty && !_isFlareActive) {
      _presencePausedForBackground = true;
      _rotatingIdRefreshTimer?.cancel();
      BlePeripheral.stopAdvertising();
      // Stopping the advertisement does not undo the rename it caused.
      // Without this the phone keeps announcing itself as a payload string
      // for as long as the app stays backgrounded, which is most of the
      // time.
      BluetoothNameGuard.restore();
    }
  }

  void _handleAppForegrounded() {
    // Check immediately on every return to the app rather than waiting out
    // whatever's left of the periodic interval — the case that actually
    // matters is coming back to a device that was banned while backgrounded.
    _syncIdentityStatus();
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
    avatarPathRevision.removeListener(_loadCurrentIdentityMetrics);
    nearbyConnectionsSessionCount.removeListener(_onNearbyConnectionsSessionCountChanged);
    chatPingRequest.removeListener(_onChatPingRequested);
    bleDirectMessageOutbox.removeListener(_onBleDirectMessageRequested);
    shortcutNotifier.removeListener(_onShortcutTriggered);
    sosTriggeredNotifier.removeListener(_onSosTriggered);
    _directMsgCycleTimer?.cancel();
    _discoverableAutoOffTimer?.cancel();
    _flareCancelTimer?.cancel();
    _bleScanResultsSubscription?.cancel();
    FlutterBluePlus.stopScan();
    BlePeripheral.stopAdvertising();
    // Fire-and-forget: dispose() cannot await, but the platform call is
    // already queued by the time this frame ends. Without it, tearing the
    // app down mid-advertisement leaves the adapter named after whatever
    // was last broadcast.
    BluetoothNameGuard.restore();
    _cleanupPairingServer();
    _radarStreamController.close();
    _pendingWatchStreamController.close();
    _watchingBuddiesStreamController.close();
    _gameEventStreamController.close();
    _diagTimer?.cancel();
    _scanRestartTimer?.cancel();
    _bleCountTimer?.cancel();
    _rotatingIdRefreshTimer?.cancel();
    _keyDirectorySyncTimer?.cancel();
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
        const SnackBar(
          content: Text("Tip: replay this walkthrough anytime from Profile → Help & Walkthrough."),
          duration: Duration(seconds: 5),
        ),
      );
    });
  }

  // ---------- Discoverable mode ----------
  //
  // Mirrors _setGameRunnerTag's shape — toggled from Radar's discoverable
  // button. Re-advertises immediately so turning it on/off is reflected
  // within seconds rather than waiting for the next incidental beacon
  // refresh.
  Future<void> _setDiscoverable(bool value) async {
    _discoverableAutoOffTimer?.cancel();
    _discoverableAutoOffTimer = null;
    setState(() => _isDiscoverable = value);
    if (_activePairingCode == null && !_isFlareActive) {
      _advertisePresenceBeacon();
    }

    if (value) {
      // Auto-off. Recurses through _setDiscoverable(false) rather than
      // duplicating the state/re-advertise logic, so "the timer expired"
      // and "the user tapped the toggle off" are the exact same code path
      // and can never drift apart.
      _discoverableAutoOffTimer = Timer(_discoverableAutoOffDuration, () {
        if (!mounted) return;
        _setDiscoverable(false);
        // The switch itself is enough feedback for a manual tap, but an
        // auto-off happening with no page open to see the toggle flip
        // would otherwise look like it silently stopped working.
        _showToastFeedbackAlert("Discoverable turned off automatically.");
      });
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
    // Restore the real presence beacon (rotating token, game-runner tag,
    // discoverable mode — whichever applies) ourselves, immediately,
    // rather than relying on the closing chat/share screen's own dispose()
    // to do it: rfcomm_chat_service.dart's dispose() only restores the
    // classic-Bluetooth adapter name it temporarily changed (see that
    // file's header comment), it doesn't know about rotating tokens/game
    // tags at all, and hops_share_page.dart's own restore predates the
    // rotating-ID scheme too. Without this, the beacon would silently stay
    // off for up to a minute until _startRotatingIdRefreshTimer's next
    // tick happened to fire.
    if (_activePairingCode == null && !_isFlareActive) {
      _advertisePresenceBeacon();
    }
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
        !_isFlareActive) {
      await _advertisePresenceBeacon();
    }
  }

  Future<void> _updateBleDeviceCount() async {
    // Don't interrupt an active pairing handshake — either side of it.
    if (_activePairingCode != null || _pairingClientActive) return;

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

  // ---------- 1:1 direct message over BLE (RFCOMM fallback) ----------
  //
  // Requested by an open chat screen via bleDirectMessageOutbox (see
  // main.dart) when RFCOMM couldn't connect. Encrypts with the key derived
  // from this device's and the peer's rotating-ID seeds, then cycles the
  // ciphertext across chunked advertisement names — the same proven
  // channel Community Alerts v3 and Emergency Flare use.
  //
  // Returns false if the message can't be sent at all: no seed exchanged
  // with this peer yet (they've never chatted successfully, so there's no
  // shared key to derive), or no local seed. The chat screen surfaces that
  // rather than silently pretending it went out.
  Future<bool> _broadcastDirectMessage(String peerUsername, String text) async {
    await _ensureRotatingSeedLoaded();
    final mySeed = _myRotatingSeed;
    final peerSeed = _contactSeeds[peerUsername];
    if (mySeed == null || peerSeed == null) return false;

    final key = deriveSharedMeshKey(mySeed, peerSeed);
    final sealed = sealDirectMessage(key: key, plaintext: text);
    final payload = base64Url.encode(sealed).replaceAll('=', '');

    final recipientTag = directMessageTag(computeRotatingToken(peerSeed));
    final senderTag = directMessageTag(computeRotatingToken(mySeed));

    final msgId = _directMsgCounter;
    _directMsgCounter = (_directMsgCounter + 1) % 64;

    final chunks = <String>[];
    for (var i = 0;
        i < payload.length && chunks.length < kDirectMessageMaxChunks;
        i += kDirectMessageTextBudget) {
      final end = (i + kDirectMessageTextBudget < payload.length)
          ? i + kDirectMessageTextBudget
          : payload.length;
      chunks.add(payload.substring(i, end));
    }
    if (chunks.isEmpty) return false;

    _directMsgCycleTimer?.cancel();
    const perChunkDuration = Duration(milliseconds: 1500);
    // One more pass than Community Alerts gets: a direct message has exactly
    // one intended recipient, so unlike a broadcast there's no "someone
    // else probably caught it" consolation if every pass is missed.
    const totalCycles = 3;

    void step(int chunkIndex, int cycle) {
      _advertiseWithName(
        encodeDirectMessageChunk(
          recipientTag: recipientTag,
          senderTag: senderTag,
          msgId: msgId,
          chunkIndex: chunkIndex,
          totalChunks: chunks.length,
          chunkPayload: chunks[chunkIndex],
        ),
        [],
      );
      _directMsgCycleTimer = Timer(perChunkDuration, () {
        if (chunkIndex + 1 < chunks.length) {
          step(chunkIndex + 1, cycle);
        } else if (cycle + 1 < totalCycles) {
          step(0, cycle + 1);
        } else {
          BlePeripheral.stopAdvertising();
          _advertisePresenceBeacon();
        }
      });
    }

    step(0, 0);
    return true;
  }

  // Reassembles an incoming DM: chunk. Only messages addressed to this
  // device's own current rotating tag are even buffered — everything else
  // on the air is someone else's conversation and is dropped immediately,
  // before any decryption is attempted.
  void _handleDirectMessageChunk(DecodedDirectMessageChunk decoded) {
    final mySeed = _myRotatingSeed;
    if (mySeed == null) return;
    if (directMessageTag(computeRotatingToken(mySeed)) != decoded.recipientTag &&
        !matchesRotatingTokenPrefix(mySeed, decoded.recipientTag)) {
      return; // not addressed to us
    }

    // Which contact does this sender tag belong to? Without a match there's
    // no key to derive, so there's nothing useful to do with the message.
    String? senderUsername;
    for (final entry in _contactSeeds.entries) {
      if (matchesRotatingTokenPrefix(entry.value, decoded.senderTag)) {
        senderUsername = entry.key;
        break;
      }
    }
    if (senderUsername == null) return;

    final key = '${decoded.senderTag}:${decoded.msgId}';
    if (_handledDirectMsgKeys.contains(key)) return;

    final buffer = _pendingDirectMsgChunks.putIfAbsent(
        key, () => _FlareSigBuffer(decoded.totalChunks));
    buffer.chunks[decoded.chunkIndex] = utf8.encode(decoded.payload);
    buffer.lastSeen = DateTime.now();

    if (buffer.isComplete) {
      _pendingDirectMsgChunks.remove(key);
      _handledDirectMsgKeys.add(key);
      Future.delayed(const Duration(minutes: 2),
          () => _handledDirectMsgKeys.remove(key));

      // Safe to decode the joined bytes in one go: the payload is base64,
      // so every chunk is pure ASCII and no character can straddle a
      // chunk boundary.
      final payload = utf8.decode(buffer.reassembled, allowMalformed: true);
      try {
        // Re-pad: base64Url.encode's '=' padding is stripped on the wire to
        // save the scarce name bytes, and the decoder requires it back.
        final padded = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
        final sealed = base64Url.decode(padded);
        final peerSeed = _contactSeeds[senderUsername]!;
        final text = openDirectMessage(
          key: deriveSharedMeshKey(mySeed, peerSeed),
          sealed: sealed,
        );
        if (text == null || text.isEmpty) return;
        bleDirectMessageInbox.add(
            BleDirectMessage(peerUsername: senderUsername, text: text));
      } catch (_) {
        // Malformed base64 or a chunk lost to the air — drop it; the
        // sender's remaining cycles may still deliver a clean copy.
      }
    }

    final staleCutoff = DateTime.now().subtract(const Duration(seconds: 45));
    _pendingDirectMsgChunks.removeWhere((_, b) => b.lastSeen.isBefore(staleCutoff));
  }

  void _onBleDirectMessageRequested() {
    final request = bleDirectMessageOutbox.value;
    if (request == null) return;
    bleDirectMessageOutbox.value = null; // one-shot, same as chatPingRequest
    _broadcastDirectMessage(request.peerUsername, request.text).then((ok) {
      if (!(request.sent?.isCompleted ?? true)) request.sent!.complete(ok);
    });
  }

  /// Learns the device's real Bluetooth name and immediately undoes any
  /// payload string a previous run left on the adapter.
  ///
  /// The restore matters as much as the capture: if the app was killed
  /// while advertising, the phone is still called "HPS:xk3f9a2b" when it
  /// next launches, and nothing else in the lifecycle would ever put that
  /// right. BluetoothNameGuard refuses to record a payload string as the
  /// original, so the value it restores to is the user's own.
  Future<void> _captureOriginalBluetoothName() async {
    await BluetoothNameGuard.capture();
    await BluetoothNameGuard.restore();
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
    // Put the device's own name back shortly after the advertisement is
    // up. The payload is already baked into the running advertisement by
    // then — setIncludeDeviceName() snapshots the name when advertising
    // starts, so renaming afterwards does not disturb what peers receive.
    // It only stops the phone from *continuing* to call itself
    // "CHT:diya:Test2" in everyone else's Bluetooth settings.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      BluetoothNameGuard.restore();
    });
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
  // Relays are QUEUED, one at a time, rather than each firing its own
  // independent advertise-then-revert pair. There is only one radio and one
  // advertisement slot, so overlapping relays used to trample each other:
  // hearing flare B while still relaying flare A replaced A's broadcast
  // mid-window, and then A's four-second timer — still armed, still
  // unaware — reverted straight to the presence beacon and cut B's relay
  // short. Two people flaring at once therefore relayed roughly one and a
  // half flares between them. Serialising means each queued payload gets
  // its own full window.
  final List<String> _emgRelayQueue = [];
  bool _emgRelayRunning = false;

  /// True from the moment our own flare starts broadcasting until its
  /// EMG_OFF: stand-down window has finished — i.e. for as long as this
  /// device has something of its own on the air that a relay must not
  /// displace.
  ///
  /// Wider than _isFlareActive on purpose. _isFlareActive goes false the
  /// instant the flare is cancelled, but the cancel then spends five more
  /// seconds broadcasting EMG_OFF:, and a relay starting inside that window
  /// would replace it — so the stand-down never reaches the people whose
  /// phones are still ringing because of us. Guarding only on _isFlareActive
  /// would have fixed the flare and left its cancellation just as fragile.
  bool _ownFlareHoldsRadio = false;

  /// How long each relayed payload is re-broadcast for before the next
  /// queued one (or the presence beacon) takes the slot back.
  static const Duration _kEmgRelayWindow = Duration(seconds: 4);

  void _scheduleEmgRelay(String localName) {
    // Our own flare outranks relaying anyone else's. Nobody else can send
    // ours, whereas theirs is being relayed by every other device that
    // heard it — so giving up the slot here would take our own emergency
    // off the air (for four seconds per relay, and silently: _isFlareActive
    // stayed true, so the UI kept insisting the flare was live) in exchange
    // for redundant coverage of someone else's.
    if (_isFlareActive || _ownFlareHoldsRadio) return;
    if (_emgRelayQueue.contains(localName)) return;
    _emgRelayQueue.add(localName);
    if (!_emgRelayRunning) _runEmgRelayQueue();
  }

  Future<void> _runEmgRelayQueue() async {
    if (_emgRelayRunning) return;
    _emgRelayRunning = true;
    try {
      while (_emgRelayQueue.isNotEmpty) {
        // Small random jitter so every device that just heard the same
        // broadcast doesn't key up the radio in perfect lockstep and collide.
        await Future.delayed(
            Duration(milliseconds: 300 + Random().nextInt(700)));
        if (!mounted) return;
        // Re-checked each pass, not just on enqueue: our own flare may have
        // started while earlier entries were being relayed.
        if (_isFlareActive || _ownFlareHoldsRadio) {
          _emgRelayQueue.clear();
          return;
        }
        final payload = _emgRelayQueue.removeAt(0);
        try {
          await _advertiseWithName(payload, []);
        } catch (_) {
          // Radio busy or momentarily unavailable — skip this payload
          // rather than abandoning everything queued behind it.
          continue;
        }
        await Future.delayed(_kEmgRelayWindow);
        if (!mounted) return;
      }
    } finally {
      _emgRelayRunning = false;
    }
    // Hand the slot back only once the queue is genuinely drained, and only
    // if nothing more important claimed it meanwhile — the old code
    // reverted unconditionally, which is how a relay that overlapped the
    // start of our own flare could kill it outright.
    if (!mounted || _isFlareActive || _ownFlareHoldsRadio) return;
    await BlePeripheral.stopAdvertising();
    await _advertisePresenceBeacon();
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
    // Held across the stand-down window too, not released with
    // _isFlareActive below — see _ownFlareHoldsRadio. A relay slipping into
    // this window would silently replace the EMG_OFF: and strand every
    // nearby phone still ringing on our behalf.
    _ownFlareHoldsRadio = true;
    _advertiseWithName("EMG_OFF:$sender", []);

    // After 5 seconds of broadcasting EMG_OFF, revert to normal HPS beacon
    Future.delayed(const Duration(seconds: 5), () {
      _ownFlareHoldsRadio = false;
      if (!mounted) return;
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

    // Known up-front to be impossible on this hardware (see
    // _bleAdvertiseSupported) — say so now rather than run the retry loop
    // below and leave the user believing help is on its way. The retries
    // would all "succeed" from Dart's point of view anyway; nothing would
    // ever leave the radio.
    if (!_bleAdvertiseSupported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                "⚠️ This phone's Bluetooth can't broadcast, so the flare can't be sent from here. "
                "Ask someone nearby to send one instead."),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 10),
          ),
        );
      }
      return;
    }

    const maxSenderLen = 8;
    const maxReasonLen = 14;
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
      debugPrint("❌ Emergency flare failed to broadcast: $lastError");
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
    debugPrint("🚨 Broadcasting emergency: $advName");

    _ownFlareHoldsRadio = true;
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
    // Best-effort, fire-and-forget — mirrors official_alert_service.dart's
    // _logAlert for the admin tier. The flare itself already went out over
    // BLE regardless of whether this succeeds; only the admin app's Action
    // Log/Dashboard record of it would be missing on failure.
    _logEmergencyFlare(reason);

    // Auto-cancel after kEmergencyFlareDuration.
    _flareCancelTimer = Timer(kEmergencyFlareDuration, () {
      _cancelEmergencyFlare(silent: true);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "Emergency flare active for ${kEmergencyFlareDuration.inSeconds} seconds"),
          backgroundColor: Colors.red,
          duration: kEmergencyFlareDuration,
          action: SnackBarAction(
            label: "CANCEL",
            textColor: Colors.white,
            onPressed: _cancelEmergencyFlare,
          ),
        ),
      );
    }
  }

  Future<void> _logEmergencyFlare(String reason) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) return;
    try {
      await Supabase.instance.client.rpc('log_emergency_flare', params: {
        'p_hops_token': token,
        'p_reason': reason,
      });
    } catch (_) {
      // Offline/unreachable — not fatal, see the call site's comment.
    }
  }

  // Official Alert (ADM:/ADM_OFF:) is composed and broadcast from the
  // separate Admin app now — see lib/services/official_alert_service.dart
  // — not from here. This app only ever receives one (below).

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
      const totalCycles = 3; // more reliability margin than Community Alerts — this one's safety-critical

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
      debugPrint("⚠️ Failed to sign alert: $e");
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
                alertKey: advName,
                sender: sender,
                reason: reason,
                adminTitle: entry.adminTitle,
                verified: true);
          } else {
            await NotificationService.updateEmergencyVerificationStatus(
                alertKey: advName, sender: sender, reason: reason, verified: true);
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
          alertKey: advName, sender: sender, reason: reason, verified: false);
      return;
    }
    await NotificationService.updateEmergencyVerificationStatus(
        alertKey: advName, sender: sender, reason: reason, verified: false);
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

  // Deletes your own Vibe Check report early. [reportKey] is the exact
  // "VBT:<location>:<level>" string VibeReportStore keys reports by (see
  // vibe_check_page.dart's onDeleteVibeReport). Not relayed — a vibe
  // report was never meant to reach past direct range, so neither does
  // deleting one; anyone who's already moved out of range simply keeps
  // whatever they last heard until it expires on its own.
  Future<void> _deleteVibeReport(String reportKey) async {
    if (!reportKey.startsWith("VBT:")) return;
    final advName = "VBX:${reportKey.substring(4)}";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  // Study Bunny Finder — structurally identical to _advertiseVibeTag above,
  // just a longer on-air window (kStudyTagAdvertiseDuration, a real study
  // session rather than a 30-second crowd snapshot) and no numeric level.
  // [id] is generated by the page (study_bunny_finder_page.dart's
  // _generateTagId) — passed in, not generated here, both so the caller
  // can record its OWN tag into StudyBunnyStore under the exact key this
  // broadcasts (same "show my own report immediately" pattern
  // _advertiseVibeTag's caller relies on) AND so this device can recognize
  // an SBI: "I'm interested" reply as addressed to THIS session — see
  // _myActiveStudyTagId below.
  String? _myActiveStudyTagId;

  Future<void> _advertiseStudyTag(String id, String subject) async {
    final advName = "SBF:$id:$subject";
    if (advName.length > 29) { _showToastFeedbackAlert("Subject too long"); return; }
    _myActiveStudyTagId = id;
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(kStudyTagAdvertiseDuration, () {
      if (!mounted) return;
      if (_myActiveStudyTagId == id) _myActiveStudyTagId = null;
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  // Ends your own study session early — mirrors _cancelEmergencyFlare's
  // "broadcast a short cancel/off signal" shape, just for SBF: instead of
  // EMG:. Not relayed: a study tag's reach was never meant to extend past
  // direct range the way Lost & Found's does, so neither does its deletion.
  Future<void> _deleteStudyTag(String id) async {
    if (_myActiveStudyTagId == id) _myActiveStudyTagId = null;
    final advName = "SBX:$id";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  // "I'm interested" tap on someone else's study tag — a brief, un-relayed
  // ping (same reasoning as _deleteStudyTag: study sessions are a direct-
  // range feature) that the ORIGINAL poster's device recognizes via the
  // SBI: scan handler matching against its own _myActiveStudyTagId.
  // Deliberately carries no identity of the tapper — study tags are
  // anonymous end to end, this doesn't create an exception.
  Future<void> _sendStudyInterest(String id) async {
    final advName = "SBI:$id";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  // The ORIGINAL poster's device broadcasting an updated interest count
  // after recognizing a new SBI: reply — so every OTHER nearby device that
  // already has this tag (from hearing its SBF:) sees the count too, not
  // just the poster. Not relayed, same as SBI:/SBX: — study tags are a
  // direct-range feature end to end.
  Future<void> _advertiseStudyInterestCount(String id, int count) async {
    final advName = "SBC:$id:$count";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    });
  }

  // Lost & Found board post. [postId] is generated by the page
  // (lost_found_board_page.dart's _generatePostId) — passed in rather than
  // generated here so the caller can record its OWN post into
  // LostFoundStore under the exact same key this broadcasts, the same
  // "show my own post immediately, since I never hear my own
  // advertisement" pattern _advertiseVibeTag's caller (vibe_check_page.dart)
  // already relies on.
  //
  // [object]/[location] are two separate fields, not one freeform line —
  // both for Lost and Found (a Found post is "found this object at this
  // location," same shape). At 30 characters each (up to 61 combined) the
  // two no longer fit in a single ~29-byte advertisement name, so this is
  // now CHUNKED and reassembled — see hops_constants.dart's
  // encodeLostFoundChunk/decodeLostFoundChunk header comment for the wire
  // format, and _runLostFoundCycle below for the actual on-air cycling.
  // Reach still comes from every RECEIVING device relaying a completed
  // post once it's fully reassembled (see the LNF: scan handler and
  // _scheduleLostFoundRelay below), not from the original sender
  // re-advertising forever.
  Future<void> _advertiseLostFound(String postId, LostFoundType type, String object, String location) async {
    final typeChar = type == LostFoundType.lost ? 'L' : 'F';
    final chunks = splitLostFoundText('$object|$location');
    unawaited(_runLostFoundCycle(postId, typeChar, chunks));
  }

  // Serializes every Lost & Found on-air cycle (posting a new one AND
  // relaying one heard from someone else) so two overlapping multi-chunk
  // cycles never fight over the single shared BLE-peripheral advertising
  // slot and corrupt each other's chunks — same problem
  // admin_ble_hub.dart's _chatSendQueue solves for Community Alerts,
  // scaled down since there's no "return once the first chunk is out"
  // contract needed here.
  Future<void> _lnfSendQueue = Future.value();
  // True for the whole duration of an in-flight multi-chunk cycle below —
  // checked by _startRotatingIdRefreshTimer so its own periodic re-advertise
  // can't clobber a chunk mid-cycle (same "skip while something more
  // important is actively advertising" guard that pairing and Emergency
  // Flare already had, just missing for this newer chunked flow). Without
  // this, a post could silently arrive on the sender's side but never
  // finish broadcasting on the air — the rotating timer only has to land
  // once during the ~2-10 second cycle to overwrite whatever chunk was
  // about to go out with the plain presence beacon instead, and every
  // reassembly buffer waiting on it then goes stale and gets dropped.
  bool _lnfCycleActive = false;

  Future<void> _runLostFoundCycle(String postId, String typeChar, List<String> chunks) async {
    final myTurn = _lnfSendQueue;
    final done = Completer<void>();
    _lnfSendQueue = done.future;
    await myTurn;

    _lnfCycleActive = true;
    try {
      const perChunkDuration = Duration(milliseconds: 1200);
      const totalCycles = 2; // repeated once for reliability, same reasoning as Community Alerts' chunk cycling
      for (var cycle = 0; cycle < totalCycles; cycle++) {
        for (var i = 0; i < chunks.length; i++) {
          if (!mounted) return;
          try {
            await _advertiseWithName(
              encodeLostFoundChunk(
                postId: postId,
                typeChar: typeChar,
                chunkIndex: i,
                totalChunks: chunks.length,
                chunkText: chunks[i],
              ),
              [],
            );
          } catch (_) {
            // Best-effort per chunk — one dropped chunk in the middle of a
            // cycle is exactly what the repeat cycle exists to cover.
          }
          await Future.delayed(perChunkDuration);
        }
      }
      if (!mounted) return;
      await BlePeripheral.stopAdvertising();
      _advertisePresenceBeacon();
      _startContinuousScan();
    } finally {
      _lnfCycleActive = false;
      if (!done.isCompleted) done.complete();
    }
  }

  // Relays a fully-reassembled Lost & Found post one hop further, the same
  // jittered "don't all key up the radio at once" pattern _scheduleEmgRelay
  // uses — this is that idea adapted for a multi-chunk broadcast instead
  // of a single fixed string, since relaying now means re-running the
  // whole chunk cycle, not replaying one advertisement.
  void _scheduleLostFoundRelay(String postId, String typeChar, String object, String location) {
    final jitter = Duration(milliseconds: 300 + Random().nextInt(700));
    Future.delayed(jitter, () {
      if (!mounted) return;
      final chunks = splitLostFoundText('$object|$location');
      unawaited(_runLostFoundCycle(postId, typeChar, chunks));
    });
  }

  // Marks a Lost & Found post resolved — either "Mark as Found" (a Lost
  // post's item turned up) or a plain "Delete" (either type). Relayed the
  // same one hop the original post was (_scheduleEmgRelay), so "it's
  // resolved" reaches everyone the post itself did, not just direct range.
  Future<void> _resolveLostFound(String postId) async {
    final advName = "LNR:$postId";
    await BlePeripheral.stopAdvertising();
    await _advertiseWithName(advName, []);
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
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
    UnreadTracker.instance.mark(UnreadSource.watchMe);
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
    // Version-aware — see services/bluetooth_permissions.dart. Requiring
    // bluetoothScan here sent every pre-Android-12 device straight back to
    // the gatekeeper on launch, since that permission cannot be granted on
    // those versions.
    final granted = await BluetoothPermissions.request();
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
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final avatarPath = prefs.getString('avatar_path');
    setState(() {
      myUsername = prefs.getString('my_username') ?? 'Unknown_User';
      _myAvatarPath = avatarPath;
      // Refreshed at every sign-in (see root_gatekeeper.dart) — drives the
      // "Admin" badge on the profile screen (profile_screen.dart reads
      // 'my_role'/'my_admin_title' from prefs itself, so this app doesn't
      // need to keep its own copy of admin_title beyond writing it below).
      _myRole = prefs.getString('my_role') ?? 'student';
    });
  }

  // Checks every incomplete task with a due date against "now", not just
  // whatever's on the currently-selected calendar date in Task Tracker —
  // and runs for as long as HopsApp itself is alive, not just while that
  // one screen happens to be open. Fires a real notification instead of
  // an in-app dialog, which could never have reached you anywhere else.
  //
  // Reminder schedule: a task with a set time (taskColStartTime — stored
  // as a time-of-day offset, see task_tracker_page.dart) gets FOUR
  // reminders counting down to it — a day before, 2 hours before, 1 hour
  // before, and right at the time. A task with no set time, just a due
  // DATE, only gets the first of those — fired at 12:00 AM the day
  // before, since "2 hours before" means nothing without a time to count
  // down to.
  void _startTaskReminderCheck() {
    _taskReminderTimer?.cancel();
    _taskReminderTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!mounted) return;
      final now = DateTime.now();
      final tasks = await DatabaseHelper.instance.getTasks();
      if (!mounted) return; // re-check — getTasks() is async, could return after unmount
      for (final task in tasks) {
        if (task[DatabaseHelper.taskColCompleted] != 0) continue;
        final dueDateMs = task[DatabaseHelper.taskColDueDate] as int?;
        if (dueDateMs == null) continue;

        final id = task[DatabaseHelper.taskColId] as String;
        final title = task[DatabaseHelper.taskColTitle] as String;
        final dueDate = DateTime.fromMillisecondsSinceEpoch(dueDateMs);
        final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
        final startMs = task[DatabaseHelper.taskColStartTime] as int?;

        if (startMs == null) {
          _maybeFireTaskReminder(
            taskId: id,
            stage: 'dayBefore',
            title: title,
            fireAt: dueDay.subtract(const Duration(days: 1)),
            now: now,
            message: '"$title" is due tomorrow.',
          );
          continue;
        }

        final taskTime = dueDay.add(Duration(milliseconds: startMs));
        final timeLabel = TimeOfDay.fromDateTime(taskTime).format(context);
        _maybeFireTaskReminder(
          taskId: id, stage: 'dayBefore', title: title, now: now,
          fireAt: taskTime.subtract(const Duration(days: 1)),
          message: '"$title" is due tomorrow at $timeLabel.',
        );
        _maybeFireTaskReminder(
          taskId: id, stage: 'twoHours', title: title, now: now,
          fireAt: taskTime.subtract(const Duration(hours: 2)),
          message: '"$title" is due in 2 hours, at $timeLabel.',
        );
        _maybeFireTaskReminder(
          taskId: id, stage: 'oneHour', title: title, now: now,
          fireAt: taskTime.subtract(const Duration(hours: 1)),
          message: '"$title" is due in 1 hour, at $timeLabel.',
        );
        _maybeFireTaskReminder(
          taskId: id, stage: 'atTime', title: title, now: now,
          fireAt: taskTime,
          message: '"$title" is due now.',
        );
      }
    });
  }

  // Fires (and dedupes) exactly one reminder stage for one task — see
  // _startTaskReminderCheck's header comment for the four stages. Reached
  // once [now] has caught up to [fireAt]; if the app was closed across
  // several thresholds (e.g. reopened the day of a task that was due
  // tomorrow last time it checked), every threshold that's since passed
  // fires in that same sweep rather than being silently skipped — a late
  // reminder is still useful, a missing one isn't.
  void _maybeFireTaskReminder({
    required String taskId,
    required String stage,
    required String title,
    required DateTime fireAt,
    required DateTime now,
    required String message,
  }) {
    final key = '$taskId:$stage';
    if (_remindedTaskStages.contains(key) || now.isBefore(fireAt)) return;
    _remindedTaskStages.add(key);
    UnreadTracker.instance.mark(UnreadSource.taskReminder);
    NotificationService.showTaskReminderNotification(
      taskTitle: title,
      body: message,
      reminderKey: key,
    );
  }

  // Pull-based stand-in for push notifications (see field comments above).
  // Best-effort — a failed/offline poll just tries again next cycle
  // rather than surfacing an error for what's meant to be invisible
  // background housekeeping. Admin privilege is granted out-of-band now
  // (see supabase/migrations/0008_admin_moderation.sql) rather than
  // requested from inside the app, so this no longer branches on
  // _isAdmin to poll a request queue — every signed-in device just asks
  // about its own current role/ban status, which also doubles as how an
  // already-signed-in student finds out they've been banned mid-session
  // (get_my_status raises account_banned exactly like sign-in does).
  Future<void> _syncIdentityStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('saved_hops_token');
    if (token == null) return;
    // Best-effort, fire-and-forget — see report_content.dart's queueReport/
    // flushPendingReports. Piggybacked on this same periodic "do we have a
    // connection" checkpoint rather than its own separate timer.
    unawaited(flushPendingReports());
    try {
      final response = await Supabase.instance.client
          .rpc('get_my_status', params: {'p_hops_token': token}).maybeSingle();
      if (response != null) {
        final unread = (response['unread_notifications'] as num?)?.toInt() ?? 0;
        // Only fire on an actual *increase* — this poll runs every 30s, so
        // reacting to any non-zero count would re-notify forever until the
        // user opened the page.
        if (unread > _unreadNotifications) {
          UnreadTracker.instance.mark(UnreadSource.notifications);
          await NotificationService.showInboxNotification();
        }
        if (unread != _unreadNotifications && mounted) {
          setState(() => _unreadNotifications = unread);
        }
        if (response['role'] == 'admin' && _myRole != 'admin') {
          await prefs.setString('my_role', 'admin');
          final adminTitle = response['admin_title'] as String?;
          if (adminTitle != null) await prefs.setString('my_admin_title', adminTitle);
          setState(() {
            _myRole = 'admin';
          });
          await NotificationService.showAdminRequestApprovedNotification();
        }
      }
    } on PostgrestException catch (e) {
      if (e.message.contains('account_banned') && mounted) {
        await NotificationService.showAccountBannedNotification();
        // Re-checked: the notification above is itself an await, and this
        // runs on a background poll that can easily outlive the screen.
        if (!mounted) return;
        await wipeLocalIdentityAndReturnToGatekeeper(context);
      } else if (e.message.contains('account_suspended') && mounted) {
        // Was previously unhandled here — get_my_status (0015) has raised
        // 'account_suspended' for a while, but this branch only ever
        // checked for 'account_banned', so it fell through to the generic
        // catch-all below and did nothing. A suspended account stayed
        // signed in on-device indefinitely (until it happened to hit some
        // *other* RPC that separately checks suspended_until) instead of
        // being signed out the same way a ban is.
        await NotificationService.showAccountSuspendedNotification(until: e.details as String?);
        if (!mounted) return;
        await wipeLocalIdentityAndReturnToGatekeeper(context);
      }
      // Any other Postgrest error: offline or Supabase unreachable, try
      // again on the next cycle.
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
  // Kept, not deleted: this is the *sending* half of the Hops & Robbers
  // runner tag, and the receiving half is still live further down (the
  // "TAG:"/"GAME_" branches in the scan handler). The game itself is
  // currently commented out of models/feature_item.dart's catalog, so
  // nothing calls this — dormant rather than dead. Deleting it would leave
  // a protocol with a parser and no writer.
  // ignore: unused_element
  void _setGameRunnerTag(bool active) {
    _isGameRunnerTagActive = active;
    _gameRunnerUsername = active ? myUsername : null;
    // Re-advertise immediately rather than waiting for the next periodic
    // refresh — a robber's proximity scan should pick up a fresh runner
    // (or stop seeing a caught one) without a up-to-1-minute lag.
    if (_activePairingCode == null && !_isFlareActive) {
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
      // pairing, Emergency Flare, and an in-flight Lost & Found chunk cycle
      // all run their own short-lived advertisement windows that this
      // shouldn't clobber (see _lnfCycleActive's comment for what went
      // wrong before this check existed).
      if (_activePairingCode != null || _isFlareActive || _lnfCycleActive) return;
      _advertisePresenceBeacon();
    });
  }

  // ---------- Can this device actually transmit? ----------
  //
  // Everything Hops sends — presence, friend requests, Emergency Flare —
  // goes out as a BLE *advertisement*, which needs the peripheral
  // (broadcaster) role. Scanning does not: any Android 5.0+ phone can hear
  // Hops traffic, but a meaningful number of budget/older handsets ship
  // chipsets whose firmware supports the central role only, and on those
  // BluetoothAdapter.isMultipleAdvertisementSupported() is false and
  // advertising silently never happens.
  //
  // That asymmetry is exactly what "the flare rings on one phone and not
  // the other" looks like from the outside, and it was completely invisible
  // before this: BlePeripheral.startAdvertising() hands the request to an
  // Android Handler and returns immediately, so a *successful* Dart call
  // proves nothing. The real verdict arrives asynchronously through
  // AdvertiseCallback.onStartFailure, which the plugin surfaces only via
  // setAdvertisingStatusUpdateCallback — never wired up until now, so every
  // advertising failure (unsupported hardware, Bluetooth mid-toggle,
  // ADVERTISE_FAILED_DATA_TOO_LARGE from an over-long advertisement name)
  // was swallowed whole. The try/catch around _advertisePresenceBeacon
  // below can't see any of them; it only catches the request being
  // rejected outright.
  bool _bleAdvertiseSupported = true;

  void _handleAdvertisingStatusUpdate(bool advertising, String? error) {
    if (error == null) return;
    debugPrint('❌ BLE advertising failed: $error');
    // A flare that failed to go out must never keep claiming it's live —
    // same rule _broadcastEmergencyFlare already applies to the errors it
    // *can* see. This is the path that catches the ones it can't.
    if (_isFlareActive) {
      _flareCancelTimer?.cancel();
      _flareCancelTimer = null;
      _flareSigCycleTimer?.cancel();
      _flareSigCycleTimer = null;
      if (mounted) {
        setState(() => _isFlareActive = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                "⚠️ Emergency flare did NOT go out ($error). Check Bluetooth is on, then try again."),
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    }
  }

  void _initializeParallelBleTransceiverEngine() async {
    if (_bleInitialized) return;
    _bleInitialized = true;
    await BlePeripheral.initialize();
    // Registered before the first advertisement so nothing can fail
    // unobserved in the gap.
    BlePeripheral.setAdvertisingStatusUpdateCallback(
        _handleAdvertisingStatusUpdate);
    try {
      // Throws (rather than returning false) on a device with no LE
      // advertiser — see the plugin's own isSupported implementation.
      _bleAdvertiseSupported = await BlePeripheral.isSupported();
    } catch (_) {
      _bleAdvertiseSupported = false;
    }
    if (!_bleAdvertiseSupported) {
      debugPrint(
          '⚠️ This device cannot advertise over BLE — receive-only Hops.');
      // Told once, plainly, rather than left to be discovered as "my flare
      // does nothing and nobody sees me on radar." Receiving still works
      // in full, so this is a warning, not a blocking error.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                "This phone's Bluetooth can receive Hops alerts but can't broadcast them — "
                "others won't see you on radar, and your Emergency Flare won't reach anyone."),
            duration: Duration(seconds: 12),
          ),
        );
      });
    }
    await _ensureRotatingSeedLoaded();
    try {
      await _advertisePresenceBeacon();
      _startRotatingIdRefreshTimer();
      debugPrint('✅ Advertising started successfully');
    } catch (e) {
      debugPrint('❌ Advertising failed: $e');
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
        // 1:1 direct message (BLE fallback for RFCOMM) — checked first and
        // `continue`d because, unlike the prefix checks below, its payload
        // is base64 that could otherwise coincidentally match another
        // prefix's shape.
        if (name.startsWith(kDirectMessagePrefix)) {
          final decoded = decodeDirectMessageChunk(name);
          if (decoded != null) _handleDirectMessageChunk(decoded);
          continue;
        }
        // Vibe Check crowd report. Handled here, in the always-on scan
        // handler, rather than inside VibeCheckPage — that page is a
        // pushed route, so detection living there meant nothing was heard
        // unless it happened to be open, and the red dot could therefore
        // only ever appear *after* you'd already gone and looked. See
        // vibe_report_store.dart.
        if (name.startsWith("VBT:")) {
          final parts = name.substring(4).split(":");
          if (parts.length == 2) {
            final level = int.tryParse(parts[1]);
            if (level != null && level >= 0 && level <= 3) {
              final isNew = VibeReportStore.instance
                  .record(key: name, location: parts[0], level: level);
              // Badge only — deliberately no system notification. A popup
              // for every crowd report nearby is noise, not information;
              // the dot is enough to say "there's something new to look
              // at" without interrupting.
              if (isNew) UnreadTracker.instance.mark(UnreadSource.vibeCheck);
            }
          }
        }
        // Someone deleting their own Vibe Check report early.
        if (name.startsWith("VBX:")) {
          final targetKey = "VBT:${name.substring(4)}";
          VibeReportStore.instance.removeReport(targetKey);
        }
        // Study Bunny Finder. Same "detect in the always-on scan handler,
        // not the feature's own page" reasoning as VBT: above — see
        // study_bunny_store.dart's header comment.
        if (name.startsWith("SBF:")) {
          // Fixed offsets, not a colon split — the subject itself is free
          // text and could contain ':'. "SBF:" (4) + id (4) + ':' (1) = 9.
          if (name.length > 9) {
            final id = name.substring(4, 8);
            final subject = name.substring(9);
            if (subject.isNotEmpty) {
              final isNew = StudyBunnyStore.instance.record(id: id, subject: subject);
              if (isNew) UnreadTracker.instance.mark(UnreadSource.studyBunny);
            }
          }
        }
        // "I'm interested" reply to a Study Bunny tag — only meaningful to
        // the device whose OWN active session this is addressed to; every
        // other device just ignores it (it's not stored, not relayed).
        // Deduped via _recentSbiIds (see its own comment) so the one
        // notification/count-bump this represents doesn't fire once per
        // scan hit of the same still-advertising SBI:.
        if (name.startsWith("SBI:")) {
          final id = name.substring(4);
          if (id.isNotEmpty && id == _myActiveStudyTagId && !_recentSbiIds.contains(id)) {
            _recentSbiIds.add(id);
            Future.delayed(const Duration(seconds: 8), () => _recentSbiIds.remove(id));
            final subject = StudyBunnyStore.instance.reports.value[id]?.subject ?? 'your session';
            await NotificationService.showStudyInterestNotification(subject: subject);
            final newCount = StudyBunnyStore.instance.incrementInterest(id);
            if (newCount != null) unawaited(_advertiseStudyInterestCount(id, newCount));
          }
        }
        // Interest-count update for a Study Bunny tag, broadcast by its
        // poster (see _advertiseStudyInterestCount) — updates the count
        // shown on every other device that already has this tag from
        // hearing its SBF:. A no-op if we never heard that SBF: at all.
        if (name.startsWith("SBC:")) {
          final parts = name.substring(4).split(':');
          if (parts.length == 2) {
            final count = int.tryParse(parts[1]);
            if (count != null) StudyBunnyStore.instance.setInterestCount(parts[0], count);
          }
        }
        // Poster deleting their own Study Bunny tag early.
        if (name.startsWith("SBX:")) {
          final id = name.substring(4);
          if (id.isNotEmpty) StudyBunnyStore.instance.remove(id);
        }
        // Lost & Found board post — unlike VBT:/SBF: above, this one also
        // RELAYS one hop further (same _scheduleEmgRelay helper Emergency
        // Flare uses) so a post reaches beyond direct BLE range. See
        // lost_found_store.dart's header comment for why.
        // Lost & Found post — chunked (see hops_constants.dart's
        // encodeLostFoundChunk/decodeLostFoundChunk), reassembled here the
        // same way Emergency Flare's signature chunks are (_pendingFlareSigChunks
        // below is the template this mirrors). Runs on every scan result
        // carrying an LNF: chunk, not just the first, since chunks keep
        // arriving for a couple of seconds after the first one appears.
        if (name.startsWith(kLostFoundPrefix)) {
          final decoded = decodeLostFoundChunk(name);
          if (decoded != null && !_handledLnfNames.contains(decoded.postId)) {
            final buffer = _pendingLnfChunks.putIfAbsent(
                decoded.postId, () => _LnfBuffer(decoded.totalChunks, decoded.typeChar));
            buffer.chunks[decoded.chunkIndex] = decoded.text;
            buffer.lastSeen = DateTime.now();
            if (buffer.isComplete) {
              _pendingLnfChunks.remove(decoded.postId);
              _handledLnfNames.add(decoded.postId);
              // Bounded the same way EMG:'s dedup is — long enough that a
              // relay storm can't loop back through a device that's
              // already relayed this exact post, short enough not to leak
              // memory over a long session.
              Future.delayed(const Duration(minutes: 2), () => _handledLnfNames.remove(decoded.postId));

              final fieldParts = buffer.reassembled.split('|');
              final object = fieldParts.isNotEmpty ? fieldParts[0] : '';
              final location = fieldParts.length > 1 ? fieldParts.sublist(1).join('|') : '';
              final type = decoded.typeChar == 'F' ? LostFoundType.found : LostFoundType.lost;
              if (object.isNotEmpty && location.isNotEmpty) {
                _scheduleLostFoundRelay(decoded.postId, decoded.typeChar, object, location);
                final isNew = LostFoundStore.instance.record(postId: decoded.postId, type: type, object: object, location: location);
                // Badge only, same restraint VBT:/SBF: use — a system
                // notification for every lost-item post nearby would be
                // noise more often than it's the specific thing you lost.
                if (isNew) UnreadTracker.instance.mark(UnreadSource.lostFound);
              }
            }
            // Drop reassembly buffers we've stopped hearing chunks for —
            // some were missed and the sender's cycle moved on.
            final staleCutoff = DateTime.now().subtract(const Duration(seconds: 20));
            _pendingLnfChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));
          }
        }
        // Lost & Found post resolved ("Mark as Found" or a plain delete) —
        // relayed the same one hop the original post was, same dedup shape
        // as LNF: itself just against its own handled-set (a resolution
        // and its original post share a postId but are different adv
        // strings, so they need independent dedup).
        if (name.startsWith("LNR:")) {
          final postId = name.substring(4);
          if (postId.isNotEmpty && !_handledLnfNames.contains(name)) {
            _handledLnfNames.add(name);
            Future.delayed(const Duration(minutes: 2), () => _handledLnfNames.remove(name));
            _scheduleEmgRelay(name);
            LostFoundStore.instance.resolve(postId);
          }
        }
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
              final now = DateTime.now();
              final last = _lastChatPingNotifiedAt[sender];
              if (last == null ||
                  now.difference(last) >= _kChatPingNotifyCooldown) {
                _lastChatPingNotifiedAt[sender] = now;
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
              UnreadTracker.instance.mark(UnreadSource.watchMe);
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
            // `continue`, not `return`: this sits inside the loop over scan
            // results, and bailing out entirely would drop every remaining
            // advertisement in the batch.
            if (!mounted) continue;
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
              // Allow the same emergency to alert again once it's had time
              // to genuinely end — kEmergencyFlareDuration plus a 5s
              // margin, not a hardcoded number that has to be remembered
              // to update every time that constant does.
              Future.delayed(kEmergencyFlareDuration + const Duration(seconds: 5), () {
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
                // The full advertisement string is the alert's identity —
                // unique per sender+reason, and already what _handledEmgNames
                // dedups on, so two concurrent flares can never collide.
                alertKey: name,
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
            // Dismiss ONLY this sender's flare. It used to cancel the one
            // shared notification unconditionally, so whoever stood down
            // first silenced everybody else's still-active alarm too —
            // "EMG_OFF:" is 8 characters, and the trailing ':' keeps the
            // match on a whole sender tag rather than a prefix of one.
            await NotificationService.cancelAlertsMatching(
                "EMG:${name.substring(8)}:");
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
                alertKey: name,
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
            // Same per-sender scoping as EMG_OFF: above — "ADM_OFF:" is
            // also exactly 8 characters.
            await NotificationService.cancelAlertsMatching(
                "ADM:${name.substring(8)}:");
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
      // Explicit, not relying on the package default — lowLatency uses
      // Android's most aggressive scan duty cycle (vs. balanced/lowPower,
      // which trade catching every advertisement for battery life). This
      // is a safety app that needs to actually hear Emergency Flare/Watch
      // Me packets in a crowded, high-BLE-traffic venue, so that trade is
      // made deliberately in favor of catching packets.
      androidScanMode: AndroidScanMode.lowLatency,
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
    // See _pairingClientActive's field comment — guards _updateBleDeviceCount
    // and _scanRestartTimer off for the whole handshake, not just the scan
    // below, since _sendAck's own brief advertise window afterward is just
    // as vulnerable to one of those landing mid-handshake.
    _pairingClientActive = true;
    try {
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
    } finally {
      _pairingClientActive = false;
    }
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

    // The built-in assistant is a contact for everyone, on every device,
    // from first launch — nobody adds it and nobody can remove it (see
    // _deleteContact). Written after the two loops above so that once
    // there's a real conversation, its last message drives the preview like
    // any other thread; `time` is overwritten either way because the
    // message loop stamps "Nearby", which is meaningless for something
    // running on this phone.
    final existingBotThread = contactThreads[kHopsBotUsername];
    contactThreads[kHopsBotUsername] = {
      'username': kHopsBotUsername,
      'lastMsg': existingBotThread?['lastMsg'] ?? 'Ask me anything — I work offline.',
      'time': '',
    };

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

    // Bot pinned to the top. Pulled out and prepended rather than sorted
    // with a comparator — Dart's List.sort isn't stable, so a comparator
    // that returns 0 for every other pair would be free to reshuffle the
    // real contacts on each refresh.
    final botEntry = contactThreads.remove(kHopsBotUsername);
    final ordered = [
      if (botEntry != null) botEntry,
      ...contactThreads.values,
    ];

    setState(() {
      localActiveContacts = ordered;
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
    // The assistant isn't removable — it ships with the app rather than
    // being something you added. Deleting is reinterpreted as clearing the
    // conversation, which is the only part of it that's actually the
    // user's, so the action still does something honest instead of being
    // silently ignored.
    if (peerName == kHopsBotUsername) {
      await DatabaseHelper.instance.deleteConversationWithPeer(peerName);
      await _refreshContactsTrayList();
      _showToastFeedbackAlert("Cleared your chat with $kHopsBotUsername.");
      return;
    }
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
            // The bot is a permanent entry in localActiveContacts (see
            // _refreshContactsTrayList), which is what friendUsernames is
            // built from — so without this filter it showed up as a
            // selectable buddy here too. It can't reciprocate a watch
            // request or drift out of Bluetooth range, so "watching" it
            // was never a real state, just an option that did nothing.
            friendUsernames:
                friendUsernames.where((u) => u != kHopsBotUsername).toSet(),
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
            onDeleteVibeReport: _deleteVibeReport,
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
    } else if (feature.id == 15) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StudyBunnyFinderPage(
            myUsername: myUsername,
            onAdvertiseStudyTag: _advertiseStudyTag,
            onSendStudyInterest: _sendStudyInterest,
            onDeleteStudyTag: _deleteStudyTag,
          ),
        ),
      );
    } else if (feature.id == 16) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LostFoundBoardPage(
            onAdvertiseLostFound: _advertiseLostFound,
            onResolveLostFound: _resolveLostFound,
          ),
        ),
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
  // [showMeta] controls the BLE-density chip + profile-avatar button block
  // below — the Contacts tab turns it off in favor of a notifications bell
  // instead (see _buildContactsTab), since neither the ambient BLE count
  // nor a shortcut to your own profile is particularly relevant while
  // you're looking at your contacts, and a bell needed a home somewhere.
  // Every other tab keeps the default.
  PreferredSizeWidget _buildSharedCustomAppBar(
    String title, {
    bool showMeta = true,
    Widget Function(ColorScheme colors)? metaReplacement,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
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
      actions: !showMeta
          ? [metaReplacement?.call(colors) ?? _buildNotificationsBellButton(colors)]
          : [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _bleMeshColor(_nearbyBleCount).withValues(alpha: 0.12),
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
                      color: _bleMeshColor(_nearbyBleCount).withValues(alpha: 0.6),
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
            child: ValueListenableBuilder<String>(
              valueListenable: CosmeticPrefs.instance.avatarFrame,
              builder: (context, frameId, _) => HopsAvatarFrame(
                frameId: frameId,
                avatarDiameter: 32,
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
          ),
        ),
      ],
    );
  }

  // Replaces the ambient BLE-density chip on the Features tab specifically
  // (see _buildFeaturesTab) — that chip is genuinely useful on the Radar/
  // Community tabs where "who else is around" is the point, but it's dead
  // weight on a tab about browsing feature cards, and the Hops Shop needed
  // a persistent home now that it's no longer an addable catalog entry.
  Widget _buildShopButton(ColorScheme colors) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const HopsShopPage()),
      ).then((_) {
        // Shop purchases/selections (avatar frame, flair, preset avatar
        // icon) can change what this app bar itself renders, so refresh
        // the same identity metrics the Profile screen refreshes on
        // return, even though the Shop was opened from here, not there.
        _loadCurrentIdentityMetrics();
      }),
      child: Container(
        margin: const EdgeInsets.only(right: 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(100),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Was a carrot emoji — reads as "your carrot balance," not
            // "open the Shop", which this button actually does. A
            // storefront icon says what tapping it does.
            Icon(Icons.storefront, size: 14, color: colors.primary),
            const SizedBox(width: 5),
            Text(
              'Hops Shop',
              style: TextStyle(
                color: colors.primary,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotificationsBellButton(ColorScheme colors) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: const Icon(Icons.notifications_outlined),
          color: colors.primary,
          tooltip: "Notifications",
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsPage()),
            ).then((_) {
              // Clear locally so the badge goes immediately, then
              // reconcile against the server rather than trusting the
              // optimistic zero forever. NotificationsPage awaits its
              // mark-all-read before popping, so this re-read returns 0
              // too — previously it didn't await, and the next poll would
              // read a stale non-zero count and re-light the dot.
              if (mounted) setState(() => _unreadNotifications = 0);
              UnreadTracker.instance.clear(UnreadSource.notifications);
              _syncIdentityStatus();
            });
          },
        ),
        if (_unreadNotifications > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.amber.shade700,
                borderRadius: BorderRadius.circular(100),
              ),
              constraints: const BoxConstraints(minWidth: 16),
              child: Text(
                _unreadNotifications > 99 ? '99+' : '$_unreadNotifications',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
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
        onRescan: () {
          FlutterBluePlus.stopScan();
          _startContinuousScan();
        },
        nearbyBleCount: _nearbyBleCount,
        isDiscoverable: _isDiscoverable,
        onSetDiscoverable: _setDiscoverable,
      ),
      _buildContactsTab(),             // index 1 — unchanged radar contacts
      CommunityAlerts(
        radarStream: radarStream,
        myUsername: myUsername,
        isVisible: _currentIndex == 2,
        // No onSendMessage — students are read-only. Only the admin app
        // (admin_community_alerts_tab.dart) composes into this feed.
      ), // index 2 — admin-only broadcast alerts, read-only here
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
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
          // Landing on a tab counts as reading whatever it holds. Feature-
          // scoped sources (index 4) are deliberately NOT cleared here —
          // those clear when the individual feature page is opened, so the
          // dot survives long enough to point at which card to tap.
          for (final source in UnreadTracker.navTabSources[index] ?? const []) {
            if (UnreadTracker.featureIds.containsKey(source)) continue;
            UnreadTracker.instance.clear(source);
          }
        },
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
      // Keyed on the OUTSIDE of the SafeArea, deliberately — see
      // navBarPillHeightNotifier's doc comment in main.dart. Measuring the
      // pill alone (inside the SafeArea) reported a height that excluded
      // the gesture-nav inset, so Community Alerts' compose bar had to add
      // MediaQuery.padding.bottom back itself — and on a Scaffold with
      // extendBody: true that inset is also still present in the body's own
      // MediaQuery, so it got counted twice and the bar floated well above
      // the pill. This reports the one number every caller actually wants:
      // total height occupied at the bottom of the screen, inset included.
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

  // Re-measured every frame the nav area lays out — its height changes
  // when the pill is tucked away/restored, at different text scales, and
  // when a badge wraps a label to a second line.
  void _reportNavAreaHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Measure whichever nav content is actually on screen, NOT the
      // Scaffold's bottomNavigationBar slot.
      //
      // This used to key a Container wrapping the AnimatedSwitcher, whose
      // layoutBuilder Stack takes the full height the Scaffold offers that
      // slot — a height the comment on that layoutBuilder already describes
      // as "often much taller than either child actually needs". Community
      // Chat reserved that inflated number as clearance, which is where the
      // stubborn gap between its input bar and the nav pill came from:
      // it was clearing empty slot, not the pill.
      //
      // Two keys rather than one because both children exist at once during
      // the switcher's 220ms transition, and a single GlobalKey on both
      // would be a duplicate-key error.
      final ctx = _navBarHidden
          ? _navHiddenKey.currentContext
          : _navPillKey.currentContext;
      final content = ctx?.size?.height;
      if (content == null || content <= 0) return;

      // Content height plus the inset the SafeArea adds beneath it: the one
      // number every caller wants is total space occupied at the bottom of
      // the screen. Callers live under extendBody: true, so the inset is
      // still in their own MediaQuery and must not be added again there.
      final total = content + MediaQuery.of(context).padding.bottom;
      if ((navBarPillHeightNotifier.value - total).abs() > 0.5) {
        navBarPillHeightNotifier.value = total;
      }
    });
  }

  // The pill itself — swiping down on it tucks it away (see
  // _buildHiddenNavIndicator for how it comes back). The small down-arrow
  // riding just above it is the visual hint that this is possible at all —
  // nothing about a normal-looking nav bar otherwise suggests it's
  // swipeable.
  // One key per nav state — see _reportNavAreaHeight for why there are two
  // and why neither sits on the bottomNavigationBar slot itself.
  final GlobalKey _navPillKey = GlobalKey();
  final GlobalKey _navHiddenKey = GlobalKey();

  Widget _buildFloatingNavBar(ColorScheme colors) {
    _reportNavAreaHeight();
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
                      color: Colors.black.withValues(alpha: 0.10),
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
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              // Rebuilds just the row of nav items when unread state
              // changes — nothing else in this screen depends on it, so a
              // full setState on every incoming message would be wasteful.
              child: ValueListenableBuilder<Set<UnreadSource>>(
                valueListenable: UnreadTracker.instance.unread,
                builder: (context, _, __) => Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildNavItem(0, Icons.home_outlined, Icons.home, "Home",
                        badgeCount: pendingRequests.length),
                    _buildNavItem(1, Icons.people_outline, Icons.people, "Contacts",
                        showDot: UnreadTracker.instance.hasForNavTab(1)),
                    _buildNavItem(2, Icons.campaign_outlined, Icons.campaign, "Alerts",
                        showDot: UnreadTracker.instance.hasForNavTab(2)),
                    _buildNavItem(3, Icons.grid_view_outlined, Icons.grid_view, "Features"),
                    _buildNavItem(4, Icons.star_outline, Icons.star, "My Features",
                        showDot: UnreadTracker.instance.hasForNavTab(4)),
                  ],
                ),
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
    // Also re-measures: tucking the pill away shrinks the bottom area to
    // just this little arrow, and anything clearing it (Community Alerts'
    // compose bar) should move down to match rather than keep a pill-sized
    // gap under it.
    _reportNavAreaHeight();
    return Padding(
      // Doubles as the AnimatedSwitcher's discriminator (it replaces a
      // ValueKey that was here for exactly that): the pill carries
      // _navPillKey, so the two children still compare as different and
      // the transition still runs.
      key: _navHiddenKey,
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
                color: Colors.black.withValues(alpha: 0.12),
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

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label,
      {int badgeCount = 0, bool showDot = false}) {
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
                    color: isSelected ? Colors.white : colors.primary.withValues(alpha: 0.6)),
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
                  )
                // Countless dot, for "something arrived here" sources where
                // a precise number isn't meaningful (a broadcast chat, a
                // feature that fired). Deliberately else-if: a tab already
                // showing a real count doesn't also need a dot.
                else if (showDot)
                  Positioned(
                    right: -3,
                    top: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: theme.scaffoldBackgroundColor, width: 1.5),
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
                  color: isSelected ? Colors.white : colors.primary.withValues(alpha: 0.6),
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
      appBar: _buildSharedCustomAppBar("Contacts", showMeta: false),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(child: localActiveContacts.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cruelty_free, size: 64, color: colors.primary.withValues(alpha: 0.18)),
                    const SizedBox(height: 16),
                    Text(
                      "No contacts yet.\nEnter a pairing code to connect.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), height: 1.4),
                    ),
                  ],
                ),
              )
            : Column(
          children: [
            // Always shown once there's at least one contact (the empty
            // state above already covers zero) — was gated behind having
            // more than 4 contacts on the theory that search is only
            // useful once scrolling gets tedious, but that just made it
            // look missing on any account (including a fresh demo one)
            // that hadn't built up a long list yet.
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _contactSearchController,
                  onChanged: (value) => setState(() => _contactSearchQuery = value),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: "Search contacts…",
                    hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.4)),
                    prefixIcon: Icon(Icons.search, size: 20, color: colors.onSurface.withValues(alpha: 0.5)),
                    suffixIcon: _contactSearchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.close, size: 18, color: colors.onSurface.withValues(alpha: 0.5)),
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
                        style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                      ),
                    )
                  : ListView.builder(
          // Bottom clearance for the floating nav pill — the Scaffold uses
          // extendBody: true so the body draws underneath it, and without
          // this the last one or two contacts end up permanently hidden
          // behind the pill with no way to scroll past it.
          padding: const EdgeInsets.fromLTRB(0, 8, 0, kFloatingNavClearance),
          itemCount: _filteredContacts.length,
          itemBuilder: (context, index) {
            final contact = _filteredContacts[index];
            final username = contact['username'] as String;
            final avatarPath = contact['avatarPath'] as String?;
            final isBot = username == kHopsBotUsername;
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
                      isBot: isBot,
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
                  // The assistant has no profile card to open — no bio, no
                  // avatar exchange, and its delete action would offer to
                  // remove something that can't be removed. Tapping the
                  // circle just opens the chat, same as the row.
                  onTap: isBot
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ContactProfileScreen(
                                peerUsername: username,
                                onDeleteContact: _deleteContact,
                              ),
                            ),
                          ).then((_) => _refreshContactsTrayList()),
                  child: isBot
                      ? const HopsBotAvatar(radius: 24)
                      : CircleAvatar(
                          radius: 24,
                          backgroundColor: colors.primary.withValues(alpha: 0.1),
                          backgroundImage:
                              avatarPath != null ? FileImage(File(avatarPath)) : null,
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
                      style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.4)),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    contact['lastMsg'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.6)),
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
    // route off of it (the pairing-code dialog) was racing the sheet's own
    // close animation. Pushing off this outer, always-mounted screen
    // context instead is what actually fixed the pairing code dialog
    // rendering as a blank dimmed screen.
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
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: colors.onSurface.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(100)))),
                const SizedBox(height: 20),
                Text("Add Peer Node", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colors.primary)),
                const SizedBox(height: 6),
                Text("Enter the 6‑character pairing code shown on your classmate's device.", style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.6))),
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
    showDialog(context: context, builder: (context) => TokenGeneratorWorkspace(
      onCodeGenerated: (code) {
        _startPairingServer(code);
      },
    )).then((_) => _refreshContactsTrayList());
  }

  Widget _buildFeaturesTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar(
        "Features",
        showMeta: false,
        metaReplacement: _buildShopButton,
      ),
      body: HopsBackgroundPattern(
        child: ListView.builder(
          // Bottom clearance for the floating nav pill — see the
          // identical fix on the Contacts tab above. Without it, the
          // last card or two stays hidden behind the pill even once
          // fully scrolled, which is what made expanding the first few
          // look like "nothing scrolls."
          padding: const EdgeInsets.fromLTRB(16, 16, 16, kFloatingNavClearance),
          itemCount: allFeatures.length,
          itemBuilder: (context, index) {
            final feature = allFeatures[index];
            final isEnabled = enabledFeatureIds.contains(feature.id);
            return _buildFeatureCard(feature, isEnabled);
          },
        ),
      ),
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
          style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
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
              style: TextStyle(fontSize: 13, color: colors.onSurface.withValues(alpha: 0.85)),
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
                      ? colors.tertiaryContainer.withValues(alpha: 0.3)
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
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The same bunny silhouette the splash screen and Hopper use
            // elsewhere, tinted to match the title text — a small brand
            // mark for the tab that's really "your Hops," not just a
            // grid of icons.
            ColorFiltered(
              colorFilter: ColorFilter.mode(colors.primary, BlendMode.srcIn),
              child: Image.asset('assets/images/hops_bunny.png', width: 22, height: 22, fit: BoxFit.contain),
            ),
            const SizedBox(width: 8),
            Text("My Features",
                style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
          ],
        ),
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
        actions: [
          TextButton.icon(
            icon: Icon(Icons.add_circle_outline, size: 18, color: colors.primary),
            label: Text("Manage", style: TextStyle(color: colors.primary)),
            // Animate the PageController the same way a nav-bar tap does
            // (see _buildNavItem's onTap comment) — a bare
            // setState(() => _currentIndex = 3) updates the nav pill's
            // highlight but never actually moves the PageView, since its
            // displayed page is driven by _pageController, not by
            // _currentIndex directly. That was the entire "Manage does
            // nothing" bug: the tab underneath never changed.
            onPressed: () => _pageController.animateToPage(
              3,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(child: orderedFeatures.isEmpty
            ? Center(
          child: Text(
            "No features added yet.\nGo to 'Features' to enable some!",
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
          ),
        )
            // Rebuilds the grid when a feature's unread state changes, so a
            // dot appears/clears without needing the tab to be reopened.
            : ValueListenableBuilder<Set<UnreadSource>>(
          valueListenable: UnreadTracker.instance.unread,
          builder: (context, _, __) => GridView.builder(
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
                      // Dot rides the icon's top-right rather than the
                      // card's — the card's own top-right corner is
                      // already the pin toggle's tap target, and this also
                      // matches how the bottom-nav items badge their icons.
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(feature.icon, size: 36, color: colors.primary),
                          if (UnreadTracker.instance.hasForFeature(feature.id))
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: theme.cardColor, width: 1.5),
                                ),
                              ),
                            ),
                        ],
                      ),
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
                              : colors.primary.withValues(alpha: 0.35),
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
        ),
        )),
      ),
    );
  }
}

// Buffers Emergency Flare signature chunks for one in-flight verification
// until every piece has arrived — see _startFlareSignatureCycle /
// _verifyFlareSignature above. Mirrors community_alerts.dart's _ChunkBuffer.
class _FlareSigBuffer {
  final int totalChunks;
  final Map<int, List<int>> chunks = {};
  DateTime lastSeen;
  _FlareSigBuffer(this.totalChunks) : lastSeen = DateTime.now();
  bool get isComplete => chunks.length >= totalChunks;
  List<int> get reassembled =>
      [for (var i = 0; i < totalChunks; i++) ...?chunks[i]];
}

// Reassembly buffer for one in-flight Lost & Found post's LNF: chunks —
// same shape as _FlareSigBuffer above, just over text chunks instead of
// byte chunks.
class _LnfBuffer {
  final int totalChunks;
  final String typeChar;
  final Map<int, String> chunks = {};
  DateTime lastSeen;
  _LnfBuffer(this.totalChunks, this.typeChar) : lastSeen = DateTime.now();
  bool get isComplete => chunks.length >= totalChunks;
  String get reassembled => [for (var i = 0; i < totalChunks; i++) chunks[i] ?? ''].join();
}