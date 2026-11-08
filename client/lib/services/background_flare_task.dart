// Hearing an Emergency Flare when the app is CLOSED.
//
// Replaces services/foreground_service.dart, which was dead code: nothing
// imported it, so FlutterForegroundTask.setTaskHandler() was never reached
// and the foreground service ran with no task handler at all. The service
// kept the process alive and showed its notification while running no Dart
// of its own — and because every BLE scan lived in _HopsAppState, a widget,
// swiping the app away destroyed the Activity, the engine, and with it the
// only thing listening. The notification stayed up saying "Scanning for
// emergency flares" while nothing was.
//
// ── How this works ────────────────────────────────────────────────────────
//
// flutter_foreground_task runs this handler in a SEPARATE Dart isolate with
// its own engine, started with the service and surviving the Activity's
// death. Plugins are registered in it, so flutter_blue_plus and
// flutter_local_notifications are usable — but NotificationService is not,
// because its state (the alert registry, isAlarmRinging, the AudioPlayer)
// lives in the UI isolate and cannot be shared. This file therefore does
// its own small, deliberately dumber job.
//
// ── Why it does not simply always scan ────────────────────────────────────
//
// The task isolate starts with the service, which is at app launch, so it
// runs ALONGSIDE the UI isolate rather than instead of it. Two scans from
// one app fight over the radio, and two listeners mean two alarms for one
// flare. So the UI isolate writes a heartbeat and this handler only takes
// over once that heartbeat goes stale.
//
// A heartbeat rather than a lifecycle callback on purpose: a swipe-away or
// a low-memory kill gives no reliable callback at all, and a flag set on
// "paused" would be wrong for a backgrounded-but-alive app that is still
// scanning perfectly well. A timestamp that simply stops being updated is
// true in every one of those cases.
//
// ── What it deliberately does NOT do ──────────────────────────────────────
//
// No relaying, no signature verification, no Watch Me, no chat, no Vibe
// Check. Only "a flare is up" and "that flare stood down". Everything else
// can wait for the app to be opened; an alarm cannot. Keeping the surface
// this small is also what makes a background isolate defensible at all.
import 'dart:async';
// SendPort, for the TaskHandler signatures. flutter_foreground_task 6.x
// still passes one even though this handler does not use it.
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/services/hops_constants.dart';

/// Prefs key the UI isolate stamps with `DateTime.now()` while it is alive.
///
/// Shared by name rather than by any isolate-aware channel because
/// SharedPreferences is the one store both isolates can reach. The reader
/// MUST call `reload()` first: each isolate keeps its own in-memory cache,
/// so without it this handler would read the value as it was when the
/// isolate started and never see another.
const String kUiHeartbeatPrefsKey = 'ui_isolate_heartbeat_ms';

/// How often the UI isolate stamps the heartbeat.
const Duration kUiHeartbeatInterval = Duration(seconds: 5);

/// How stale the heartbeat must be before this handler decides the UI is
/// gone and starts listening itself.
///
/// Four heartbeats. Long enough that a slow frame, a GC pause or a device
/// doze does not hand over while the app is working fine; short enough that
/// a closed app is covered within about the time it takes to put a phone in
/// a pocket.
const Duration kUiConsideredGoneAfter = Duration(seconds: 20);

/// Entry point for the background isolate.
///
/// `@pragma('vm:entry-point')` is required: this is invoked by name from
/// native code, so tree-shaking would otherwise remove it in a release
/// build and the service would start with no handler — exactly the state
/// this file exists to fix, but harder to notice because debug would work.
@pragma('vm:entry-point')
void startBackgroundFlareTask() {
  FlutterForegroundTask.setTaskHandler(BackgroundFlareTaskHandler());
}

class BackgroundFlareTaskHandler extends TaskHandler {
  static const String _channelId = 'emergency_flare_background';

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _scanning = false;
  bool _notificationsReady = false;

  /// Alerts this handler has already raised, keyed by the full
  /// advertisement string, mapped to the notification id showing it.
  ///
  /// Keyed on the whole string for the same reason hops_app.dart is: it is
  /// already unique per sender and reason, so two people flaring at once
  /// get two notifications instead of one overwriting the other.
  final Map<String, int> _shown = <String, int>{};

  /// When each alert was last heard, so one can expire if its stand-down
  /// never arrives. A stand-down is a broadcast like any other and can
  /// simply be missed; without this an orphan would ring until reboot.
  final Map<String, DateTime> _lastHeard = <String, DateTime>{};

  /// When each alert was last *raised*, kept across a stand-down so the
  /// same still-airborne advertisement cannot immediately re-raise it.
  ///
  /// Deliberately separate from [_shown], which a stand-down empties — see
  /// the comment in _handleAlert for what went wrong when one map did both
  /// jobs.
  final Map<String, DateTime> _raisedRecently = <String, DateTime>{};

  /// How long a stood-down or expired alert stays un-raisable.
  ///
  /// Matches the UI isolate's `_handledEmgNames` lifetime exactly
  /// (`kEmergencyFlareDuration + 5s`) so a flare is forgotten at the same
  /// moment on both paths. It must comfortably exceed [_kFreshness], or
  /// the stale advertisement outlives the cooldown and the bug returns.
  static final Duration _kRaiseCooldown =
      kEmergencyFlareDuration + const Duration(seconds: 5);

  int _nextId = 7300;

  /// Our own sender tag as it appears on the wire, or null until read.
  ///
  /// Refreshed from prefs on every tick rather than cached once: this
  /// isolate outlives sign-outs and account switches, and a stale tag here
  /// means either alarming on our own flare or — worse — silently dropping
  /// a real one from whoever now holds the old name.
  String? _myTag;

  @override
  void onStart(DateTime timestamp, SendPort? sendPort) {
    debugPrint('BackgroundFlareTask: started');
  }

  /// Driven by ForegroundTaskOptions.interval rather than a Timer of its
  /// own, so the plugin's own wakeups are the only thing keeping this
  /// isolate busy.
  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {
    _tick();
  }

  @override
  void onDestroy(DateTime timestamp, SendPort? sendPort) {
    debugPrint('BackgroundFlareTask: destroyed');
    _stopScan();
  }

  Future<void> _tick() async {
    await _refreshMyTag();
    final uiGone = await _isUiGone();
    if (uiGone && !_scanning) {
      await _startScan();
    } else if (!uiGone && _scanning) {
      // The app is back and is scanning for itself. Stand down rather than
      // compete for the radio or double-notify.
      debugPrint('BackgroundFlareTask: UI is back, handing the radio over');
      await _stopScan();
      // Hand the ALERTS back too, not just the radio.
      //
      // Once scanning stops this handler can never hear the matching
      // EMG_OFF:, so anything it raised would hang in the shade — still
      // ringing, impossible to stand down, and only cleared by killing
      // the app. The UI isolate is scanning now and raises its own alert
      // for any flare still on the air, so dropping these loses nothing
      // and leaves exactly one owner for every alarm.
      await _clearOwnAlerts();
    }
    _expireStaleAlerts();
  }

  /// Re-reads our username from prefs and truncates it the way the wire
  /// format does.
  ///
  /// `my_username` is the key root_gatekeeper.dart writes on sign-in. A
  /// failure leaves [_myTag] as it was rather than nulling it, since the
  /// safe direction here is to keep filtering our own flares.
  Future<void> _refreshMyTag() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final name = prefs.getString('my_username');
      if (name != null && name.isNotEmpty) _myTag = senderTagFor(name);
    } catch (_) {
      // Keep whatever we had.
    }
  }

  /// Cancels every notification this handler currently owns.
  ///
  /// Leaves [_raisedRecently] alone: the advertisement is still on the air,
  /// so forgetting it here would let this handler re-raise the moment the
  /// UI goes away again, on top of the UI's own alert.
  Future<void> _clearOwnAlerts() async {
    if (_shown.isEmpty) return;
    for (final entry in _shown.entries) {
      await _dismissQuietly(entry.value);
      debugPrint('BackgroundFlareTask: handed "${entry.key}" to the UI');
    }
    _shown.clear();
    _lastHeard.clear();
  }

  /// Cancels a notification without letting a platform failure escape.
  ///
  /// An uncaught throw here is worse than in the UI isolate: it aborts
  /// _tick(), so the expiry sweep never runs and the handover never
  /// completes. R8 with no keep rules made every cancel() throw (see
  /// android/app/proguard-rules.pro) and this handler stopped mid-tick
  /// every time it tried to hand alerts back.
  Future<void> _dismissQuietly(int id) async {
    try {
      await _notifications.cancel(id);
    } catch (e) {
      debugPrint('BackgroundFlareTask: could not dismiss $id ($e)');
    }
  }

  Future<bool> _isUiGone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Mandatory — see kUiHeartbeatPrefsKey. Without it this isolate reads
      // a snapshot taken when it started and the answer never changes.
      await prefs.reload();
      final beat = prefs.getInt(kUiHeartbeatPrefsKey);
      if (beat == null) return true;
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(beat));
      return age > kUiConsideredGoneAfter;
    } catch (e) {
      // Fail toward listening. Being wrong this way risks a duplicate
      // notification; being wrong the other way means a missed emergency.
      debugPrint('BackgroundFlareTask: heartbeat unreadable ($e) — listening');
      return true;
    }
  }

  // ── Scanning ────────────────────────────────────────────────────────────

  Future<void> _startScan() async {
    _scanning = true;
    try {
      await _ensureNotifications();
      _scanSub = FlutterBluePlus.scanResults.listen(
        _onScanResults,
        onError: (Object e) =>
            debugPrint('BackgroundFlareTask: scan stream error — $e'),
      );
      await FlutterBluePlus.startScan(
        androidUsesFineLocation: true,
        continuousUpdates: true,
        withServices: [Guid(HOPS_SERVICE_UUID)],
        androidScanMode: AndroidScanMode.lowLatency,
      );
      debugPrint('BackgroundFlareTask: listening for flares');
    } catch (e) {
      // Most likely a permission the user has since revoked, or Bluetooth
      // switched off. Reset so the next tick retries rather than sitting in
      // a half-started state believing it is listening.
      debugPrint('BackgroundFlareTask: could not start scanning — $e');
      _scanning = false;
      await _scanSub?.cancel();
      _scanSub = null;
    }
  }

  Future<void> _stopScan() async {
    _scanning = false;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Already stopped, or the adapter went away. Nothing to recover.
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final r in results) {
      final name = r.advertisementData.advName;
      if (name.isEmpty) continue;

      // Only ACTIVE advertisements. scanResults accumulates for the life of
      // the scan and never drops an entry (no removeIfGone), so a flare
      // heard once would otherwise be re-raised forever — the same trap
      // that produced phantom watch requests in the UI isolate. See
      // test/views/handshake_freshness_invariant_test.dart.
      if (DateTime.now().difference(r.timeStamp) > _kFreshness) continue;

      if (name.startsWith('EMG_OFF:') || name.startsWith('ADM_OFF:')) {
        _handleStandDown(name);
      } else if (name.startsWith('EMG:') || name.startsWith('ADM:')) {
        // Never alarm the phone that raised it. The UI isolate has always
        // had this check and this handler never did, so a flare raised and
        // then backgrounded for 20 seconds came back as an alarm on the
        // sender's own phone — which they then could not stand down,
        // because reopening the app to try stops this handler scanning
        // before the EMG_OFF: ever arrives.
        if (isOwnAlert(name, _myTag)) continue;
        _handleAlert(name);
      }
    }
  }

  static const Duration _kFreshness = Duration(seconds: 20);

  /// How long an alert rings without being re-heard before it self-expires.
  ///
  /// Derived rather than written down: this was a hardcoded 3 minutes, and
  /// the moment kEmergencyFlareDuration went to 5 the handler would have
  /// been willing to expire an alert while the sender was still
  /// broadcasting it. The margin matches NotificationService's
  /// _alertAutoExpiry, so the UI and background paths time out alike.
  static final Duration _kAlertExpiry =
      kEmergencyFlareDuration + const Duration(seconds: 30);

  void _handleAlert(String name) {
    final now = DateTime.now();

    // "Already showing" and "already raised" are DIFFERENT questions, and
    // conflating them made the stand-down look broken.
    //
    // _handleStandDown removes the key from _shown — but the flare's own
    // EMG: entry is still sitting in the accumulated scanResults list with
    // a timestamp a second old, so it passes the freshness check above for
    // up to _kFreshness longer. Keyed on _shown alone, the very next
    // emission found no entry and raised the alert again under a new id:
    // the alarm died and came straight back, which from the far end is
    // indistinguishable from the stand-down never arriving.
    //
    // So remember what has been raised separately from what is on screen,
    // and for the same window the UI isolate's _handledEmgNames uses, so
    // both paths forget a flare at the same time.
    if (!shouldRaiseFlare(
        raisedAt: _raisedRecently[name], now: now, cooldown: _kRaiseCooldown)) {
      // Only push the expiry deadline out while it is actually showing;
      // a stood-down alert has no deadline left to extend.
      if (_shown.containsKey(name)) _lastHeard[name] = now;
      return;
    }
    _raisedRecently.remove(name);

    _lastHeard[name] = now;
    _raisedRecently[name] = now;

    final isOfficial = name.startsWith('ADM:');
    final body = name.substring(4); // both 'EMG:' and 'ADM:' are 4
    final parts = body.split(':');
    final sender = parts.isNotEmpty ? parts.first : 'someone';
    final reason = parts.length > 1 ? parts.sublist(1).join(':') : '';

    final id = _nextId++;
    _shown[name] = id;
    unawaited(_notify(
      id: id,
      title: isOfficial ? '🚨 Official Alert' : '🚨 Emergency Flare',
      body: reason.isEmpty
          ? '$sender needs help nearby.'
          : '$sender: $reason',
    ));
    debugPrint('BackgroundFlareTask: raised "$name" as id $id');
  }

  void _handleStandDown(String name) {
    final gone = flareKeysStoodDownBy(_shown.keys, name);
    for (final key in gone) {
      final id = _shown.remove(key);
      _lastHeard.remove(key);
      // _raisedRecently is deliberately NOT touched: the flare's own
      // advertisement is still in scanResults and still fresh, and
      // forgetting it here is exactly what re-raised the alarm a
      // millisecond after cancelling it.
      if (id != null) unawaited(_dismissQuietly(id));
      debugPrint('BackgroundFlareTask: stood down "$key"');
    }
  }

  void _expireStaleAlerts() {
    final now = DateTime.now();
    final stale = _lastHeard.entries
        .where((e) => now.difference(e.value) > _kAlertExpiry)
        .map((e) => e.key)
        .toList(growable: false);
    for (final key in stale) {
      final id = _shown.remove(key);
      _lastHeard.remove(key);
      if (id != null) unawaited(_dismissQuietly(id));
      debugPrint('BackgroundFlareTask: expired "$key"');
    }

    // _raisedRecently is NOT cleared alongside the two above — that is the
    // whole point of it. Pruned on its own schedule instead, or a long-run
    // service would accumulate one entry per flare it ever heard.
    _raisedRecently.removeWhere(
        (_, at) => now.difference(at) > _kRaiseCooldown);
  }

  // ── Notifications ───────────────────────────────────────────────────────

  /// A channel of this handler's own, distinct from NotificationService's.
  ///
  /// Two reasons. Channel ids are immutable once created, and this one needs
  /// settings NotificationService's deliberately does not have — it sets
  /// `playSound: false` because the UI isolate drives an AudioPlayer itself,
  /// which is not dependable in a background isolate. Here the OS plays the
  /// sound, at ALARM usage so it is loud and ignores a silenced ringer the
  /// way an alarm should.
  ///
  /// The trade, stated plainly: the OS plays the channel sound ONCE rather
  /// than looping it the way the in-app siren does. A single loud alarm tone
  /// plus a full-screen intent is what is reliably achievable with no UI
  /// isolate, and it is vastly better than the silence this replaces.
  Future<void> _ensureNotifications() async {
    if (_notificationsReady) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications
        .initialize(const InitializationSettings(android: androidInit));
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      'Emergency Flare (app closed)',
      description:
          'Flares and official alerts heard while Hops is not open.',
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    ));
    _notificationsReady = true;
  }

  Future<void> _notify({
    required int id,
    required String title,
    required String body,
  }) async {
    await _ensureNotifications();
    await _notifications.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Emergency Flare (app closed)',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          // Wakes and shows over the lock screen. The whole point is that
          // this reaches someone whose phone is in a pocket.
          fullScreenIntent: true,
          // Swipeable, and dismissible by hand. ongoing:true left an alert
          // raised here with no way to clear it at all: this isolate has
          // no "Stop for me" handler to tap, so the only exit was killing
          // the app.
          ongoing: false,
          autoCancel: true,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          actions: [
            // cancelNotification: true makes ANDROID dismiss this, with no
            // Dart callback involved. That is the difference from
            // NotificationService's copy of this button, and it is
            // deliberate: a tap handler registered in the UI isolate does
            // not exist while the app is closed, which is precisely when
            // this notification is shown. The OS plays this channel's tone
            // once rather than looping it, so dismissing the notification
            // IS "stop for me" here — there is no siren left running
            // behind it.
            AndroidNotificationAction(
              'dismiss',
              'Stop for me',
              cancelNotification: true,
            ),
          ],
        ),
      ),
    );
  }
}
/// Which of [active] raise-keys a stand-down advertisement cancels.
///
/// Pure and top-level so it can be tested without a background isolate,
/// plugins or a radio — which is the only way this gets covered at all.
///
/// THE TRAILING COLON IS LOAD-BEARING. Matching "EMG:<sender>" without it
/// also matches a different user whose truncated tag merely STARTS with
/// this one's, and silences their alarm too. Sender tags are truncated to
/// 8 characters on the wire, so "vic" and "victor" are a realistic pair.
/// This is the same rule NotificationService.cancelAlertsMatching follows,
/// and the reason the unscoped cancel must never be used from a
/// stand-down path.
///
/// Returns an empty list for anything malformed rather than guessing, since
/// the alternative when in doubt is silencing someone else's emergency.
/// A username truncated to the 8 characters the wire format carries.
///
/// Sender tags are cut to 8 on the way out, so comparing a full username
/// against one straight off the air never matches for anyone with a longer
/// name — which would disable the own-flare filter precisely for the users
/// most likely to collide.
String senderTagFor(String username) =>
    username.length > 8 ? username.substring(0, 8) : username;

/// Whether an `EMG:`/`ADM:` advertisement is this device's own.
///
/// Compares the sender segment EXACTLY, not by prefix. A `startsWith`
/// here would make "Vic" swallow a real flare from "Victor12" — the same
/// bug the UI isolate had and fixed, and a realistic collision between two
/// test accounts on one campus.
///
/// Returns false when [myTag] is unknown: an unexpected alarm on your own
/// phone is a nuisance, a dropped flare from someone else is the failure
/// this whole file exists to prevent.
bool isOwnAlert(String advertisementName, String? myTag) {
  if (myTag == null || myTag.isEmpty) return false;
  final colon = advertisementName.indexOf(':');
  if (colon < 0) return false;
  final body = advertisementName.substring(colon + 1);
  final end = body.indexOf(':');
  final sender = end < 0 ? body : body.substring(0, end);
  return sender == myTag;
}

/// Whether an alert heard again should be raised, or is still inside the
/// cooldown from the last time it was raised.
///
/// Pulled out as a pure function for the same reason
/// [flareKeysStoodDownBy] is: the bug it exists to prevent is otherwise
/// only reachable with two physical devices and a stopwatch.
///
/// The rule: a flare is raised once, and not again until [cooldown] has
/// passed — **whether or not it was stood down in between**. Standing down
/// does not make it raisable again, because the advertisement that caused
/// it is still on the air and still fresh for up to _kFreshness longer, so
/// re-raising would undo the stand-down the instant it landed.
bool shouldRaiseFlare({
  required DateTime? raisedAt,
  required DateTime now,
  required Duration cooldown,
}) {
  if (raisedAt == null) return true;
  return now.difference(raisedAt) >= cooldown;
}

List<String> flareKeysStoodDownBy(
  Iterable<String> active,
  String standDownName,
) {
  const prefixes = {'EMG_OFF:': 'EMG:', 'ADM_OFF:': 'ADM:'};
  final match = prefixes.entries
      .where((e) => standDownName.startsWith(e.key))
      .toList(growable: false);
  if (match.isEmpty) return const [];

  final sender = standDownName.substring(match.first.key.length);
  if (sender.isEmpty) return const [];

  // Only the matching KIND stands down: an EMG_OFF: must not silence an
  // admin Official Alert from a same-named account, and vice versa.
  final wanted = '${match.first.value}$sender:';
  return active.where((k) => k.startsWith(wanted)).toList(growable: false);
}
