// lib/services/admin_ble_hub.dart
//
// Central BLE lifecycle owner for the whole admin app. Two things it exists
// to fix:
//
//   1. BlePeripheral.initialize() was never being called anywhere in the
//      admin app — official_alert_service.dart's broadcast() went straight
//      to BlePeripheral.startAdvertising(), which the plugin requires
//      initialize() to have run before, so every Official Alert attempt
//      threw on all 3 retries and surfaced as "Failed to start
//      broadcasting — check Bluetooth is on" regardless of the adapter's
//      actual state. ensureStarted() below is the one place that call
//      happens now, gated so it only ever runs once per process.
//
//   2. The Listening Post (admin_alert_tab.dart) and Admin Community Alerts
//      (admin_community_alerts_tab.dart) both need a continuous, HOPS_SERVICE_
//      UUID-filtered scan feeding them ScanResults — same shape as
//      hops_app.dart's single shared radarStream. Without one owner, each
//      tab starting/stopping its own scan on its own tab-switch lifecycle
//      would fight over the one underlying platform scan (flutter_blue_plus
//      has exactly one active scan configuration at a time), so this owns
//      it for the whole app's lifetime instead — mirroring how HopsApp
//      itself is the sole owner of the student app's scan.
//   3. Emergency Flare / Official Alert monitoring has to run whenever the
//      admin app is running — not only while its screen happens to be
//      open. It used to live entirely inside admin_alert_tab.dart's
//      _ListeningPost widget, which sits in a lazily-built TabBarView, so
//      an incoming EMG: flare raised no alarm at all unless a guard
//      happened to already be looking at that exact sub-tab. For a feature
//      whose whole job is alerting someone to an emergency they aren't
//      watching for, that was the wrong place for it. Detection,
//      verification and the alarm now live here; _ListeningPost is just a
//      view onto liveAlerts below.
import 'dart:async';
import 'dart:convert';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:crypton/crypton.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/services/notification_service.dart';

enum AlertKind { sos, official }

enum AlertVerifyState { pending, verified, failed }

class LiveAlert {
  final AlertKind kind;
  final String sender;
  final String reason;
  String? adminTitle;
  DateTime lastSeen;
  int rssi;
  AlertVerifyState verify;
  LiveAlert({
    required this.kind,
    required this.sender,
    required this.reason,
    required this.rssi,
    this.adminTitle,
    this.verify = AlertVerifyState.pending,
  }) : lastSeen = DateTime.now();
}

class _SigBuffer {
  final int totalChunks;
  final Map<int, List<int>> chunks = {};
  DateTime lastSeen;
  _SigBuffer(this.totalChunks) : lastSeen = DateTime.now();
  bool get isComplete => chunks.length >= totalChunks;
  List<int> get reassembled => [for (var i = 0; i < totalChunks; i++) ...?chunks[i]];
}

class AdminBleHub {
  AdminBleHub._();
  static final AdminBleHub instance = AdminBleHub._();

  bool _started = false;
  final _controller = StreamController<List<ScanResult>>.broadcast();

  /// Every Hops advertisement this device has seen since ensureStarted() —
  /// the admin-app equivalent of hops_app.dart's radarStream.
  Stream<List<ScanResult>> get scanStream => _controller.stream;

  /// Currently-active flares and Official Alerts, keyed "EMG:<sender>" /
  /// "ADM:<sender>". The Dashboard's live-alerts section renders this; it
  /// does not maintain it (see reason 3 in this file's header).
  final ValueNotifier<Map<String, LiveAlert>> liveAlerts =
      ValueNotifier<Map<String, LiveAlert>>({});

  final Map<String, _SigBuffer> _sigBuffers = {}; // keyed by advName
  final Set<String> _sigHandled = {};

  /// Call once, after Bluetooth permissions are granted (see
  /// admin_sign_in_screen.dart) and before anything tries to advertise or
  /// scan. Safe to call repeatedly — every call after the first is a no-op.
  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    // Needed to verify a signature from someone this device hasn't synced
    // since — best-effort, same as everywhere else.
    KeyDirectory.sync();
    await BlePeripheral.initialize();
    // Registered before the first advertisement so nothing can fail
    // unobserved in the gap — the same ordering hops_app.dart uses.
    BlePeripheral.setAdvertisingStatusUpdateCallback(
        _handleAdvertisingStatusUpdate);
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      continuousUpdates: true,
      withServices: [Guid(HOPS_SERVICE_UUID)],
    );
    // Held so restart() can tear them down. They're still never cancelled
    // in normal operation — the hub runs for the admin app's whole process
    // lifetime — but Settings' "Restart" needs something to actually stop,
    // and previously had nothing: it called ensureStarted(), which returns
    // immediately once _started is set, so the button did nothing at all.
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      _controller.add(results);
      _scanForAlerts(results);
    });
    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pruneStale());
  }

  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _pruneTimer;

  // ── Did the radio actually accept the last advertisement? ──────────────
  //
  // BlePeripheral.startAdvertising() posts to an Android Handler and
  // returns immediately, so awaiting it proves NOTHING about whether the
  // advertisement went out. The real verdict arrives asynchronously on
  // AdvertiseCallback.onStartFailure, surfaced only through
  // setAdvertisingStatusUpdateCallback.
  //
  // The admin app never registered that callback, so a rejected
  // advertisement was indistinguishable from a sent one: the await
  // succeeded, broadcastAdminChatMessage returned a msgId, the alert
  // appeared in the admin's own list looking delivered, and nothing had
  // left the radio. That is the single worst shape a bug can take in this
  // app, and it is exactly the failure reported as "the alert doesn't
  // send" with no error anywhere.
  //
  // Reported through a notifier rather than a callback so the UI can show
  // it wherever it makes sense without this service knowing about widgets.
  final ValueNotifier<String?> lastAdvertisingError = ValueNotifier(null);

  /// Set while a broadcast is in flight, so an asynchronous failure can be
  /// attributed to it rather than to some unrelated later advertisement.
  bool _broadcastInFlight = false;
  bool _broadcastFailed = false;

  void _handleAdvertisingStatusUpdate(bool advertising, String? error) {
    if (error == null) return;
    debugPrint('Admin BLE advertising failed: $error');
    if (_broadcastInFlight) _broadcastFailed = true;
    lastAdvertisingError.value = _describeAdvertisingError(error);
  }

  /// Turns the plugin's raw error into something an admin can act on.
  static String _describeAdvertisingError(String error) {
    final e = error.toUpperCase();
    if (e.contains('DATA_TOO_LARGE')) {
      // The one that silently ate long alerts. Worth naming precisely,
      // because the admin's only visible symptom is a message that never
      // arrives and the instinct is to blame the receiving phone.
      return 'the alert was too long for this phone to broadcast';
    }
    if (e.contains('TOO_MANY_ADVERTISERS')) {
      return 'the Bluetooth radio is busy — try again in a moment';
    }
    if (e.contains('NOT_SUPPORTED') || e.contains('FEATURE_UNSUPPORTED')) {
      return 'this phone cannot broadcast over Bluetooth, only receive';
    }
    if (e.contains('INTERNAL_ERROR')) {
      return 'the Bluetooth radio reported an internal error';
    }
    return 'Bluetooth refused to broadcast it ($error)';
  }

  /// Genuinely stops and restarts the scan. For the "my device has stopped
  /// hearing anything" case, where the radio is in a bad state and the only
  /// fix short of relaunching is a fresh startScan.
  ///
  /// Deliberately does NOT clear liveAlerts: an alert that is still being
  /// broadcast will be re-heard within seconds, and blanking the list would
  /// make a live emergency vanish from the Dashboard mid-incident.
  Future<void> restart() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // Wasn't scanning, or the adapter is off — starting fresh below is
      // still the right next move either way.
    }
    _sigBuffers.clear();
    _sigHandled.clear();
    _started = false;
    await ensureStarted();
  }

  // ── Flare / Official Alert monitoring ──────────────────────────────────

  void _scanForAlerts(List<ScanResult> results) {
    var changed = false;
    final alerts = Map<String, LiveAlert>.from(liveAlerts.value);

    for (final r in results) {
      final name = r.advertisementData.advName;

      if (name.startsWith("EMG:") || name.startsWith("ADM:")) {
        final isOfficial = name.startsWith("ADM:");
        final parts = name.substring(4).split(':');
        final sender = parts.isNotEmpty ? parts[0] : '';
        final reason = parts.length > 1 ? parts.sublist(1).join(':') : 'Emergency';
        if (sender.isEmpty) continue;

        final key = "${isOfficial ? 'ADM' : 'EMG'}:$sender";
        final existing = alerts[key];
        if (existing == null) {
          alerts[key] = LiveAlert(
            kind: isOfficial ? AlertKind.official : AlertKind.sos,
            sender: sender,
            reason: reason,
            rssi: r.rssi,
          );
          changed = true;
          // Fires once per newly-seen alert, not per scan result for it.
          // Keyed by the full advertisement string, same as the student app
          // — the hub's own `key` is sender-only (it's what dedups repeat
          // sightings of one alert), which is too coarse to identify a
          // notification.
          if (isOfficial) {
            NotificationService.showOfficialAlertNotification(
                alertKey: name, sender: sender, reason: reason);
          } else {
            NotificationService.showEmergencyNotification(
                alertKey: name, sender: sender, reason: reason);
          }
        } else {
          existing.lastSeen = DateTime.now();
          existing.rssi = r.rssi;
        }

        final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
        if (mfgBytes != null && !_sigHandled.contains(name)) {
          final decoded = decodeFlareSigChunk(mfgBytes);
          if (decoded != null) {
            final buffer = _sigBuffers.putIfAbsent(name, () => _SigBuffer(decoded.totalChunks));
            buffer.chunks[decoded.chunkIndex] = decoded.bytes;
            buffer.lastSeen = DateTime.now();
            if (buffer.isComplete) {
              _sigBuffers.remove(name);
              _sigHandled.add(name);
              Future.delayed(const Duration(seconds: 40), () => _sigHandled.remove(name));
              _verify(name, Uint8List.fromList(buffer.reassembled),
                  requireAdmin: isOfficial, key: key);
            }
          }
          final staleCutoff = DateTime.now().subtract(const Duration(seconds: 20));
          _sigBuffers.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));
        }
      }

      if (name.startsWith("EMG_OFF:") || name.startsWith("ADM_OFF:")) {
        final isOfficial = name.startsWith("ADM_OFF:");
        // "EMG_OFF:" and "ADM_OFF:" are both exactly 8 characters.
        final key = "${isOfficial ? 'ADM' : 'EMG'}:${name.substring(8)}";
        if (alerts.remove(key) != null) {
          changed = true;
          // Notifications are per-alert now, so this cancels exactly the
          // one that stood down. The old workaround — only dismiss when
          // nothing else was live — was forced by the single shared id, and
          // had the opposite failure: with a second alert still up, the
          // stood-down one's notification was left ringing indefinitely.
          NotificationService.cancelAlertsMatching("$key:");
        }
      }
    }

    if (changed) liveAlerts.value = alerts;
  }

  Future<void> _verify(String advName, Uint8List signature,
      {required bool requireAdmin, required String key}) async {
    final sender = advName.substring(4).split(':').first;
    final candidates = await KeyDirectory.candidatesForTruncatedUsername(sender);
    for (final candidate in candidates) {
      final entry = candidate.value;
      if (requireAdmin && entry.role != 'admin') continue;
      try {
        final publicKey = RSAPublicKey.fromString(entry.publicKey);
        final valid = publicKey.verifySHA256Signature(
            Uint8List.fromList(utf8.encode(advName)), signature);
        if (valid) {
          final alert = liveAlerts.value[key];
          if (alert != null) {
            alert.verify = AlertVerifyState.verified;
            alert.adminTitle = entry.adminTitle;
            liveAlerts.value = Map<String, LiveAlert>.from(liveAlerts.value);
          }
          if (requireAdmin) {
            NotificationService.updateOfficialAlertVerificationStatus(
                alertKey: advName,
                sender: sender,
                reason: alert?.reason ?? '',
                adminTitle: entry.adminTitle,
                verified: true);
          } else {
            NotificationService.updateEmergencyVerificationStatus(
                alertKey: advName,
                sender: sender,
                reason: alert?.reason ?? '',
                verified: true);
          }
          return;
        }
      } catch (_) {
        // Wrong candidate or malformed key — try the next.
      }
    }

    final alert = liveAlerts.value[key];
    if (alert != null) {
      alert.verify = AlertVerifyState.failed;
      liveAlerts.value = Map<String, LiveAlert>.from(liveAlerts.value);
    }
    // Same asymmetry as the student app: an unverified personal SOS is
    // still worth showing, but an Official Alert that fails verification is
    // an active spoofing attempt and its alarm is cancelled outright.
    if (requireAdmin) {
      NotificationService.updateOfficialAlertVerificationStatus(
          alertKey: advName,
          sender: sender,
          reason: alert?.reason ?? '',
          verified: false);
    } else {
      NotificationService.updateEmergencyVerificationStatus(
          alertKey: advName,
          sender: sender,
          reason: alert?.reason ?? '',
          verified: false);
    }
  }

  void _pruneStale() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 45));
    final alerts = Map<String, LiveAlert>.from(liveAlerts.value);
    final before = alerts.length;
    alerts.removeWhere((_, a) => a.lastSeen.isBefore(cutoff));
    if (alerts.length != before) liveAlerts.value = alerts;
  }

  int _chatMsgCounter = 0;

  // Serializes consecutive broadcastAdminChatMessage calls so two messages
  // (the parts of one auto-split long alert — see hops_constants.dart's
  // splitIntoAlertParts — or just two separate alerts sent close together)
  // never cycle chunks on the shared BlePeripheral radio at the same time.
  // It can only ever advertise ONE local name at once, so two overlapping
  // cycles would each keep interrupting the other's stopAdvertising()/
  // startAdvertising() pair via their own independent Timers, corrupting
  // both messages' reassembly on every receiving device. Each call's own
  // advertising work now waits for the PREVIOUS call's full cycle (not just
  // its first chunk) to finish before it starts; the Future this method
  // returns to its caller still resolves as soon as its own turn's first
  // chunk is confirmed, same prompt-feedback contract as before.
  Future<void> _chatSendQueue = Future.value();

  /// Broadcasts one Community Alerts message as this admin's own identity —
  /// an admin's tag is their own (truncated) username rather than an
  /// anonymizing rotating token, since the whole point of an admin
  /// speaking up is that it's identifiably them. Uses the v3 advertisement
  /// local-name format (see hops_constants.dart's kCommunityNameBudget for
  /// why the earlier scan-response manufacturer-data encoding was
  /// abandoned). This is the only place in the app that composes a
  /// Community Alerts message — students are read-only (see
  /// community_alerts.dart).
  /// Returns false if the message could not be put on the air at all.
  ///
  /// It used to return void and fire the first advertise without awaiting
  /// it or catching anything, so a failure (BlePeripheral not initialized
  /// yet, BLUETOOTH_ADVERTISE not granted on this run, adapter busy)
  /// disappeared into an unhandled async error and the send silently did
  /// nothing — the message appeared in the admin's own list and never left
  /// the device. The first chunk is now awaited specifically so there's a
  /// real answer to report back to the composer.
  /// Returns the 6-bit msgId the message went out under, or null if
  /// advertising couldn't start at all.
  ///
  /// Returns as soon as the first chunk is on the air rather than waiting
  /// out every repeat cycle — the caller wants to know "did this leave the
  /// device", which is answered by then, and the id is needed promptly so
  /// the admin's own copy can be tagged for a possible later deletion.
  Future<int?> broadcastAdminChatMessage(String message, String adminUsername) async {
    // Claim a place in line: whoever called this before us gets `myTurn`
    // (our predecessor's cycleDone future); we publish our OWN cycleDone as
    // the new queue tail before awaiting anything, so a caller that arrives
    // while we're still waiting our turn correctly queues behind us, not
    // behind whoever we're waiting on. This all happens synchronously
    // (nothing here awaits yet), so there's no race between two calls
    // arriving back-to-back.
    final myTurn = _chatSendQueue;
    final cycleDone = Completer<void>();
    _chatSendQueue = cycleDone.future;

    // Guaranteed to complete no matter which path below returns/throws —
    // otherwise a failure between here and the first successful chunk would
    // leave cycleDone forever incomplete, and every call queued behind us
    // would hang waiting for a turn that never comes.
    void finishTurn() {
      if (!cycleDone.isCompleted) cycleDone.complete();
    }

    await myTurn; // wait for the previous call's full cycle to finish

    try {
      // Guarantees BlePeripheral.initialize() has actually run — the admin
      // app can reach this screen on a restored session without ever having
      // passed through sign-in, so nothing else on the path is certain to
      // have done it.
      await ensureStarted();
    } catch (e) {
      finishTurn();
      return null;
    }

    final msgId = _chatMsgCounter;
    // 64, not 256 — msgId is one 6-bit character in the v3 name format.
    _chatMsgCounter = (_chatMsgCounter + 1) % 64;

    final chunks = splitCommunityMessage(message);

    const perChunkDuration = Duration(milliseconds: 1500);
    // MORE repeats for longer messages, not fewer. This used to be inverted
    // (3 cycles for <=3 chunks, only 2 beyond that) on an airtime-cost
    // argument — a max-length 8-chunk alert already spends nearly a minute
    // on the air, so cycling it a third time was cut to save time. That
    // reasoning had it backwards for what this channel actually is now:
    // reassembly needs EVERY chunk to arrive, so a message needing more
    // chunks has more independent chances for one to be missed, and is
    // exactly the message that most needs the extra pass — not the one that
    // can least afford it. An alert is sent once, rarely, and matters more
    // than a chat message; spending under a minute of airtime to reliably
    // land an 8-chunk alert is a good trade, and this is the fix for admins
    // reporting long alerts failing to arrive.
    final totalCycles = chunks.length <= 3 ? 3 : 4;

    Future<void> advertiseChunk(int index) async {
      final localName = encodeCommunityNameChunk(
        senderTag: adminUsername,
        msgId: msgId,
        chunkIndex: index,
        totalChunks: chunks.length,
        chunkText: chunks[index],
        isAdmin: true,
      );
      // Refused here rather than handed to a radio that will reject it on
      // a callback this code used to ignore. Same guard _advertiseWithName
      // applies in the student app; the admin path never had one, so an
      // over-long chunk failed silently and the alert simply never arrived.
      if (!advertisementNameFits(localName)) {
        throw StateError('chunk $index is '
            '${utf8.encode(localName).length} bytes, over the '
            '$kAdvertisementNameMaxBytes-byte advertisement ceiling');
      }
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.startAdvertising(
        localName: localName,
        services: [HOPS_SERVICE_UUID],
      );
    }

    void step(int chunkIndex, int cycle) {
      // Later chunks stay best-effort: by this point the message is
      // already going out, and one dropped chunk in the middle of a cycle
      // is what the repeat cycles exist to cover.
      advertiseChunk(chunkIndex).catchError((_) {});
      Timer(perChunkDuration, () {
        if (chunkIndex + 1 < chunks.length) {
          step(chunkIndex + 1, cycle);
        } else if (cycle + 1 < totalCycles) {
          step(0, cycle + 1);
        } else {
          // Cycling is genuinely done — safe for the next queued call (the
          // next part of a split alert, most commonly) to start its own.
          _broadcastInFlight = false;
          BlePeripheral.stopAdvertising();
          finishTurn();
        }
      });
    }

    // First chunk awaited and checked — if advertising can't start at all,
    // say so now rather than spinning through a full cycle pretending.
    _broadcastFailed = false;
    _broadcastInFlight = true;
    try {
      await advertiseChunk(0);
    } catch (e) {
      _broadcastInFlight = false;
      lastAdvertisingError.value = e is StateError
          ? 'the alert was too long for this phone to broadcast'
          : 'Bluetooth refused to broadcast it';
      finishTurn();
      return null;
    }

    // The await above proves only that the call was accepted for posting.
    // Give onStartFailure a moment to land before claiming success —
    // otherwise a rejected advertisement still returns a msgId and the
    // alert shows as sent. This is the whole reason the callback exists.
    await Future.delayed(const Duration(milliseconds: 250));
    if (_broadcastFailed) {
      _broadcastInFlight = false;
      await BlePeripheral.stopAdvertising();
      finishTurn();
      return null;
    }

    Timer(perChunkDuration, () {
      if (chunks.length > 1) {
        step(1, 0);
      } else if (totalCycles > 1) {
        step(0, 1);
      } else {
        BlePeripheral.stopAdvertising();
        finishTurn();
      }
    });
    return msgId;
  }

  /// Broadcasts "remove this message" to every device in range.
  ///
  /// Repeated for [_deleteBroadcastSeconds] rather than sent once, for the
  /// same reason chat messages cycle: a single advertisement is easily
  /// missed, and a missed deletion leaves the message sitting on someone's
  /// screen. A deletion is worth more repetition than a chat message —
  /// re-hearing one is harmless (removing an already-removed message is a
  /// no-op) whereas missing one is the whole failure.
  ///
  /// Returns false if advertising couldn't start at all.
  static const int _deleteBroadcastSeconds = 12;

  Future<bool> broadcastMessageDeletion({
    required String senderTag,
    required int msgId,
    required CommunityDeleteReason reason,
  }) async {
    await ensureStarted();

    final name = encodeCommunityDeletion(
      senderTag: senderTag,
      msgId: msgId,
      reason: reason,
    );

    try {
      await BlePeripheral.stopAdvertising();
      await BlePeripheral.startAdvertising(
        localName: name,
        services: [HOPS_SERVICE_UUID],
      );
    } catch (_) {
      return false;
    }

    Timer(const Duration(seconds: _deleteBroadcastSeconds), () {
      // Best-effort stop: if this throws the advertisement lapses on its
      // own the next time anything else advertises.
      BlePeripheral.stopAdvertising().catchError((_) {});
    });
    return true;
  }
}
