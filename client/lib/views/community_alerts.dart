// lib/views/community_alerts.dart
//
// Formerly Community Chat — anyone nearby could broadcast into a shared
// thread. Repurposed to Community Alerts: only Hops admins can post; every
// other Hops user is a read-only recipient. Two reasons this is a straight
// repurpose rather than a rewrite:
//
//   1. The wire format was already fine. v3 (chunked advertisement LOCAL
//      NAME — see hops_constants.dart) is the same channel EMG:/FR:/HOP:/
//      VBT: use, the one BLE mechanism this app has confirmed working on
//      real hardware. Nothing about *delivery* needed fixing.
//   2. A free-for-all broadcast thread and an admin-only alert channel need
//      the same reassembly/dedup/persistence/moderation machinery — only
//      who's allowed to add to it differs. So this keeps that machinery
//      (see _ChunkBuffer, _resolveSenderAndAdd, the CX: deletion path) and
//      changes two things: the compose UI only renders for widget.amAdmin,
//      and _listenToRadar now discards anything that doesn't decode as an
//      admin-tagged (CA:) chunk before it's even buffered — enforced on the
//      receiving end, not just hidden in the UI, so a forged CM: broadcast
//      from an ordinary account can't inject a fake "alert" into the feed.
//
// kCommunityChatPrefix ('CM:', the plain non-admin tag) still exists in
// hops_constants.dart and still decodes — nothing in this app emits it
// anymore, but the decoder accepting it costs nothing and there's no reason
// to make the wire format itself refuse a shape it doesn't currently see.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/key_directory.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/main.dart' show navBarPillHeightNotifier;
import 'package:client/utils/report_content.dart';
// Only ever touched when widget.amAdmin is true (the admin app), but the
// import is unconditional — Dart has no conditional imports on runtime
// state, and the hub is a lazy singleton that does nothing until started.
import 'package:client/services/admin_ble_hub.dart';
import 'package:client/services/community_alert_sync.dart';

class CommunityMessage {
  final String sender;
  final String text;
  final DateTime timestamp;
  final bool isMe;
  // Always true for anything actually shown now — see _resolveSenderAndAdd,
  // which refuses to add a message from any sender that doesn't resolve to
  // a confirmed admin account. Kept as a field (rather than assumed) because
  // it still drives the bubble's admin styling and JSON round-trips old
  // local history.
  final bool isAdmin;

  // The sender's REAL account name, resolved from the wire tag. An admin's
  // alert is meant to be attributable — that's the entire point of
  // restricting who can send — so unlike the old Community Chat, this is
  // also what gets DISPLAYED, not just what reports are filed against.
  //
  // Null when this device couldn't match the tag to any cached account
  // (directory never synced, or synced before that account existed) — see
  // _resolveSenderAndAdd, which now drops the message entirely rather than
  // showing it unattributed, since an alert nobody can attribute to a real
  // admin account isn't one this feed should trust.
  final String? realUsername;

  /// Wire identity of this message: the sender tag and 6-bit id it arrived
  /// under. Kept so an admin deletion (CX:, see hops_constants.dart) can be
  /// matched against it — that pair is exactly how the receiver already
  /// keys messages during reassembly, so nothing new goes on the wire.
  ///
  /// Null for this device's own outgoing messages, which were never
  /// received and so were never keyed.
  final String? senderTag;
  final int? msgId;

  /// Set once an admin has removed this message for everyone. The text is
  /// kept in the object but never rendered — the bubble becomes a tombstone
  /// naming the reason. Holding on to it means a deletion that arrives
  /// twice, or after a restart, stays idempotent.
  final CommunityDeleteReason? deletedReason;

  bool get isDeleted => deletedReason != null;

  const CommunityMessage({
    required this.sender,
    required this.text,
    required this.timestamp,
    required this.isMe,
    this.isAdmin = false,
    this.realUsername,
    this.senderTag,
    this.msgId,
    this.deletedReason,
  });

  CommunityMessage copyWith({CommunityDeleteReason? deletedReason}) =>
      CommunityMessage(
        sender: sender,
        text: text,
        timestamp: timestamp,
        isMe: isMe,
        isAdmin: isAdmin,
        realUsername: realUsername,
        senderTag: senderTag,
        msgId: msgId,
        deletedReason: deletedReason ?? this.deletedReason,
      );

  Map<String, dynamic> toJson() => {
    'sender': sender,
    'text': text,
    'ts': timestamp.millisecondsSinceEpoch,
    'isMe': isMe,
    'isAdmin': isAdmin,
    'realUsername': realUsername,
    'senderTag': senderTag,
    'msgId': msgId,
    'deletedReason': deletedReason?.index,
  };

  factory CommunityMessage.fromJson(Map<String, dynamic> j) =>
      CommunityMessage(
        sender: j['sender'] as String,
        text: j['text'] as String,
        timestamp:
        DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isMe: j['isMe'] as bool,
        // Absent on history persisted before these fields existed — the
        // defaults are the correct read for those, not a crash.
        isAdmin: j['isAdmin'] as bool? ?? false,
        realUsername: j['realUsername'] as String?,
        senderTag: j['senderTag'] as String?,
        msgId: j['msgId'] as int?,
        deletedReason: _reasonFromIndex(j['deletedReason'] as int?),
      );

  /// Range-checked rather than indexed directly: a stored index from a
  /// build with more reasons would throw while loading history, which is a
  /// blank Community Alerts feed rather than one odd message.
  static CommunityDeleteReason? _reasonFromIndex(int? i) =>
      (i != null && i >= 0 && i < CommunityDeleteReason.values.length)
          ? CommunityDeleteReason.values[i]
          : null;
}

// Buffers chunks for one in-flight message until every piece has arrived.
class _ChunkBuffer {
  final int totalChunks;
  final Map<int, String> chunks = {};
  DateTime lastSeen;
  _ChunkBuffer(this.totalChunks) : lastSeen = DateTime.now();
  bool get isComplete => chunks.length >= totalChunks;
  String get reassembled =>
      List.generate(totalChunks, (i) => chunks[i] ?? '').join();
}

class CommunityAlerts extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  /// Sends the alert over BLE and returns the 6-bit msgId it was broadcast
  /// under, or null if the sender doesn't track one. Null (unset) on the
  /// student side entirely — only the admin app ever composes, so there's
  /// nothing to send there.
  ///
  /// The id comes back so this device's own copy can be tagged with the
  /// same wire identity everyone else keys it by — without that, an admin
  /// deletion removed the message from every device except the one that
  /// posted it, which is the device whose author most needs to see it go.
  final Future<int?> Function(String message)? onSendMessage;

  /// Why the last [onSendMessage] returned null, in words an admin can act
  /// on — e.g. "the alert was too long for this phone to broadcast".
  ///
  /// Supplied by the admin app, which is the only side that can know: the
  /// radio's verdict arrives on an asynchronous callback owned by
  /// AdminBleHub. Without it the failure snackbar could only guess, and it
  /// guessed "check Bluetooth is on" — actively misleading when Bluetooth
  /// was on and the real problem was the length of the message.
  final String? Function()? describeSendFailure;
  final String myUsername;

  // True when this is the tab currently on screen. Every tab in HopsApp's
  // PageView stays mounted whether or not it's selected, so `mounted` says
  // nothing about whether the user is actually looking at this — which is
  // exactly what decides between "show a live message" and "raise a badge
  // and a notification". Defaults true for standalone use (the admin app
  // shows this as a whole tab of its own).
  final bool isVisible;

  // True when this instance is running inside the Admin app (see
  // admin_community_alerts_tab.dart) — the ONLY thing that decides whether
  // the compose bar renders at all. Received messages are always styled and
  // attributed as admin messages regardless of this flag (every message
  // that survives _resolveSenderAndAdd already is one); this only controls
  // whether THIS device can add to the feed.
  final bool amAdmin;

  const CommunityAlerts({
    super.key,
    required this.radarStream,
    required this.myUsername,
    this.onSendMessage,
    this.describeSendFailure,
    this.amAdmin = false,
    this.isVisible = true,
  });

  @override
  State<CommunityAlerts> createState() => _CommunityAlertsState();
}

class _CommunityAlertsState extends State<CommunityAlerts> {
  // v1 under the new name deliberately — this is a fresh feed, not a
  // continuation of Community Chat's history. Old local history could
  // contain ordinary students' messages from before this repurpose, which
  // have no business surviving as "alerts" once the feature's meaning
  // changed; a new key just leaves that old data inert rather than trying
  // to filter it after the fact.
  static const _prefsKey = 'community_alerts_v1';
  static const int _maxStored = 100;
  // A single wire message tops out at kAlertPartMaxBytes worth of reliable
  // capacity (see hops_constants.dart's splitIntoAlertParts for why that's
  // 3 chunks' worth rather than the full 8-chunk ceiling), but a composed
  // alert isn't limited to one wire message anymore — _send() splits
  // anything longer into up to kAlertMaxParts separate broadcasts. This is
  // the composer's overall guide-rail on that, in characters rather than
  // bytes (a non-ASCII character costs more than one byte, same caveat
  // splitCommunityMessage always had), matched to what splitIntoAlertParts
  // will actually fit before it has to start trimming.
  static const int _maxMsgLen = kAlertMaxParts * kAlertPartMaxBytes;

  List<CommunityMessage> _messages = [];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription? _streamSub;
  bool _isSending = false;
  // Progress for a multi-part send — 0/0 outside of sending, or e.g. 2/3
  // while the second of three split parts is in flight. Drives the small
  // status line in the composer so a long alert taking a while doesn't
  // read as the app being stuck.
  int _sendingIndex = 0;
  int _sendingTotal = 0;

  final Map<String, _ChunkBuffer> _pendingChunks = {}; // key: "sender:msgId"
  final Map<String, DateTime> _completedMsgKeys = {}; // msgKey -> shown-at

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _listenToRadar();
    // Server catch-up. The fetch itself runs on HopsApp's periodic poll,
    // not here — this page only exists once its tab has been built, so a
    // fetch living here would never run for a student who has not opened
    // it. This just merges whatever that poll collected, including
    // anything collected while this page did not exist.
    CommunityAlertSync.instance.pending.addListener(_mergeServerAlerts);
    _mergeServerAlerts();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    CommunityAlertSync.instance.pending.removeListener(_mergeServerAlerts);
    _streamSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Server catch-up ───────────────────────────────────────────────────────

  /// Folds alerts fetched from the server into this feed.
  ///
  /// Three things make this safe to run repeatedly and in any order
  /// relative to the BLE path:
  ///
  ///   * Deduplicated on (senderTag, msgId) — the same pair the radio
  ///     receiver keys reassembly on — so an alert that arrives by both
  ///     routes appears once. An alert whose radio send failed has no tag
  ///     and falls back to author plus timestamp.
  ///   * No KeyDirectory lookup. A server row carries the author's real
  ///     username and could only have been written by an account the
  ///     server itself confirmed was an admin (post_community_alert checks
  ///     the role), so there is nothing to verify locally. That is the
  ///     fragile step this path exists to bypass: a device that has never
  ///     synced the directory drops every CA: chunk silently, Bluetooth
  ///     working perfectly.
  ///   * Tombstones are applied to messages already held, so an alert
  ///     withdrawn after this device received it over BLE still gets
  ///     withdrawn here.
  Future<void> _mergeServerAlerts() async {
    final incoming = CommunityAlertSync.instance.pending.value;
    if (incoming.isEmpty) return;

    var changed = false;
    for (final a in incoming) {
      final existingIndex = _messages.indexWhere((m) {
        if (a.senderTag != null && a.msgId != null) {
          return m.senderTag == a.senderTag && m.msgId == a.msgId;
        }
        return m.realUsername == a.authorUsername &&
            m.timestamp.millisecondsSinceEpoch ==
                a.createdAt.millisecondsSinceEpoch;
      });

      if (existingIndex == -1) {
        if (a.isDeleted) {
          // Withdrawn before this device ever saw it — nothing to show and
          // nothing to tombstone. Adding it just to cross it out would
          // surface a message the admin had already retracted.
          continue;
        }
        _messages.add(CommunityMessage(
          sender: a.authorUsername,
          text: a.body,
          timestamp: a.createdAt,
          isMe: false,
          isAdmin: true,
          realUsername: a.authorUsername,
          senderTag: a.senderTag,
          msgId: a.msgId,
        ));
        changed = true;
      } else if (a.isDeleted && !_messages[existingIndex].isDeleted) {
        _messages[existingIndex] = _messages[existingIndex].copyWith(
          deletedReason: _tombstoneReason(a.deletedReason),
        );
        changed = true;
      }
    }

    if (!changed) {
      CommunityAlertSync.instance.clearPending();
      return;
    }

    // Chronological: BLE arrivals and a server catch-up interleave by
    // nature, and appending would show a missed alert from an hour ago
    // below one that arrived a minute ago.
    _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (mounted) {
      setState(() {});
      // Same "is the user actually looking at this" test the BLE path uses
      // — see _resolveSenderAndAdd. A catch-up fetch is exactly the case
      // where they are not.
      final looking = widget.isVisible &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (!looking) {
        UnreadTracker.instance.mark(UnreadSource.communityAlerts);
      } else {
        _scrollToBottom();
      }
    }
    await _persist();
    CommunityAlertSync.instance.clearPending();
  }

  /// Server stores the reason as a small int; the wire format and the UI
  /// use the enum.
  ///
  /// Distinct from CommunityMessage._reasonFromIndex, which returns null
  /// for an unknown value. This one never does, deliberately: it feeds
  /// copyWith(deletedReason:), which treats null as "leave unchanged", so
  /// a null here would silently fail to tombstone the message. A slightly
  /// wrong label still correctly hides withdrawn text, which is the part
  /// that matters.
  CommunityDeleteReason _tombstoneReason(int? index) {
    if (index == null ||
        index < 0 ||
        index >= CommunityDeleteReason.values.length) {
      return CommunityDeleteReason.values.first;
    }
    return CommunityDeleteReason.values[index];
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey) ?? '[]';
    try {
      final list = (json.decode(raw) as List)
          .cast<Map<String, dynamic>>()
          .map(CommunityMessage.fromJson)
          .toList();
      if (mounted) {
        setState(() => _messages = list);
        _scrollToBottom();
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = _messages.length > _maxStored
        ? _messages.sublist(_messages.length - _maxStored)
        : List<CommunityMessage>.from(_messages);
    await prefs.setString(
      _prefsKey,
      json.encode(trimmed.map((m) => m.toJson()).toList()),
    );
  }

  // ── Radar listener — chunk reassembly ─────────────────────────────────────

  // Resolves a chunk's truncated-username tag against the cached public
  // directory and adds the completed message — but only once that tag
  // actually resolves to an account cached with role 'admin'. Anyone can
  // claim the CA: prefix; the resolution against KeyDirectory is what
  // actually verifies it, and a claim that doesn't resolve is dropped
  // rather than shown some lesser way — there's no legitimate reason for a
  // message in this feed to exist without a confirmed admin behind it.
  //
  // Async (KeyDirectory reads from SharedPreferences on first use), so it's
  // kept outside the synchronous per-batch loop in _listenToRadar and
  // manages its own setState/_persist/scroll rather than folding into that
  // loop's shared state.
  Future<void> _resolveSenderAndAdd(
      String tag, int msgId, String text, DateTime now) async {
    // Permanent guard against re-adding a message already in the list,
    // independent of _completedMsgKeys' 90-second memory — see the original
    // Community Chat comment this carries forward: a stale BLE-scan-cache
    // redelivery arriving after that window shouldn't produce a duplicate
    // bubble no matter how late it arrives.
    if (_messages.any((m) => m.senderTag == tag && m.msgId == msgId)) return;

    final candidates = await KeyDirectory.candidatesForTruncatedUsername(tag);
    String? resolvedName;
    for (final candidate in candidates) {
      if (candidate.value.role != 'admin') continue;
      resolvedName = candidate.key;
      break;
    }

    // No confirmed-admin candidate — either a spoofed CA: from an ordinary
    // account, or an admin this device's directory hasn't synced yet (or
    // has since been demoted). Either way, not something this feed shows.
    if (resolvedName == null) return;

    if (!mounted) return;

    // Badge + system notification — but only when this screen isn't the
    // thing being looked at right now. Community Alerts lives in a PageView
    // inside HopsApp, so "mounted" isn't enough to tell: every tab stays
    // mounted regardless of which one is on screen. widget.isVisible is
    // what HopsApp uses to say "this is the selected tab", and the
    // lifecycle check covers the app being backgrounded entirely.
    final looking = widget.isVisible &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!looking) {
      UnreadTracker.instance.mark(UnreadSource.communityAlerts);
      NotificationService.showCommunityMessageNotification(
        sender: resolvedName,
        message: text,
      );
    }

    setState(() {
      _messages.add(CommunityMessage(
        sender: resolvedName!,
        text: text,
        timestamp: now,
        isMe: false,
        isAdmin: true,
        realUsername: resolvedName,
        senderTag: tag,
        msgId: msgId,
      ));
    });
    await _persist();
    _scrollToBottom();
  }

  /// Applies an admin deletion to whichever local message it names.
  ///
  /// Idempotent by design — the same deletion is re-broadcast for several
  /// seconds and will be heard many times. Doing nothing when the message
  /// is already deleted also stops it re-persisting and re-rendering on
  /// every scan result for the length of the broadcast.
  Future<void> _applyDeletion(DecodedCommunityDeletion deletion) async {
    var changed = false;
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.isDeleted) continue;
      if (m.senderTag != deletion.senderTag || m.msgId != deletion.msgId) continue;
      _messages[i] = m.copyWith(deletedReason: deletion.reason);
      changed = true;
    }
    if (!changed) return;
    setState(() {});
    await _persist();
  }

  void _listenToRadar() {
    _streamSub = widget.radarStream.listen((results) {
      final now = DateTime.now();

      for (final r in results) {
        // Admin "remove this message" broadcasts, checked before chat
        // chunks: CX: is its own prefix and would decode as nothing else,
        // but handling it first keeps the two paths from sharing state.
        final deletion = decodeCommunityDeletion(r.advertisementData.advName);
        if (deletion != null) {
          _applyDeletion(deletion);
          continue;
        }

        // v3: chunks ride the advertisement local name, not scan-response
        // manufacturer data — see hops_constants.dart's kCommunityNameBudget
        // comment for why that channel was abandoned.
        final decoded = decodeCommunityNameChunk(r.advertisementData.advName);
        if (decoded == null || decoded.senderTag.isEmpty) continue;

        // Community Alerts is admin-only by design — discard anything that
        // didn't arrive under the admin prefix (CA:) before it's even
        // buffered. This is the enforcement, not the compose bar being
        // hidden: even a modified client broadcasting plain CM: chunks
        // can't get a message into this feed.
        if (!decoded.isAdmin) continue;

        // Skip our own broadcasts (admin composing) — the tag is the
        // sender's truncated username.
        final myTag = widget.myUsername.length > kCommunityNameSenderTagChars
            ? widget.myUsername.substring(0, kCommunityNameSenderTagChars)
            : widget.myUsername.padRight(kCommunityNameSenderTagChars, '_');
        if (decoded.senderTag == myTag) continue;

        final msgKey = '${decoded.senderTag}:${decoded.msgId}';
        if (_completedMsgKeys.containsKey(msgKey)) continue; // already shown

        final buffer = _pendingChunks.putIfAbsent(
            msgKey, () => _ChunkBuffer(decoded.totalChunks));
        buffer.chunks[decoded.chunkIndex] = decoded.text;
        buffer.lastSeen = now;

        if (buffer.isComplete) {
          _pendingChunks.remove(msgKey);
          _completedMsgKeys[msgKey] = now;
          // Resolved against the whole cached public directory — not just
          // this device's contacts — so an alert shows for every nearby
          // Hops user, not only people already paired with. See
          // _resolveSenderAndAdd.
          _resolveSenderAndAdd(decoded.senderTag, decoded.msgId,
              buffer.reassembled, now);
        }
      }

      // Drop buffers for messages we've stopped hearing chunks for (some
      // were missed and the sender's cycle has moved on or finished).
      final staleCutoff = now.subtract(const Duration(seconds: 15));
      _pendingChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));

      // Forget completed keys after a while — msgId is only 0-63 per
      // sender in the v3 format, and without this a wrapped-around id
      // would be mistaken for the old message and silently dropped
      // forever.
      final forgetCutoff = now.subtract(const Duration(seconds: 90));
      _completedMsgKeys.removeWhere((_, seenAt) => seenAt.isBefore(forgetCutoff));
      // No setState/_persist here: every completed message is now handed
      // to _resolveSenderAndAdd, which is async (the directory lookup) and
      // therefore owns its own state update once it resolves.
    });
  }

  // ── Sending (admin only) ─────────────────────────────────────────────────

  /// Sends this device's own message [text] (one part of a possibly
  /// multi-part alert) and backfills its wire identity once broadcast
  /// starts. Shared by both the single-part and split-alert paths in
  /// _send() below — the only difference between them is how many times
  /// this gets called and awaited.
  Future<void> _sendOnePart(String text, int index) async {
    final msgId = await widget.onSendMessage!(text);
    // Null means the broadcast never started. Said out loud, because the
    // message is already sitting in this device's own list looking sent —
    // which is exactly how a message that reached nobody passed for a
    // delivered one.
    if (msgId == null && mounted) {
      final why = widget.describeSendFailure?.call();
      final reason = why ?? 'check Bluetooth is on';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_sendingTotal > 1
            ? "Part $_sendingIndex of $_sendingTotal couldn't broadcast — $reason."
            : "Couldn't broadcast — $reason."),
        duration: const Duration(seconds: 5),
      ));
    }
    // Backfill the wire identity so an admin deletion can find this copy
    // too. Guarded on the index still holding the same message: received
    // messages can land in the list while the broadcast is starting.
    if (msgId != null && index < _messages.length) {
      final mine = _messages[index];
      if (mine.isMe && mine.text == text && mine.senderTag == null) {
        final tag = widget.myUsername.length > kCommunityNameSenderTagChars
            ? widget.myUsername.substring(0, kCommunityNameSenderTagChars)
            : widget.myUsername.padRight(kCommunityNameSenderTagChars, '_');
        _messages[index] = CommunityMessage(
          sender: mine.sender,
          text: mine.text,
          timestamp: mine.timestamp,
          isMe: true,
          isAdmin: true,
          realUsername: mine.realUsername,
          senderTag: tag,
          msgId: msgId,
        );
        await _persist();
      }
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    // The compose bar only ever renders for widget.amAdmin (which is the
    // only case onSendMessage is non-null in practice) — this null check is
    // defensive, not reachable through the normal UI.
    if (text.isEmpty || _isSending || widget.onSendMessage == null) return;

    _controller.clear();

    // An alert longer than one wire message's reliable capacity is split
    // into several — see hops_constants.dart's splitIntoAlertParts for why
    // this beats raising the per-message ceiling. Most alerts are short
    // enough that this returns exactly one part, in which case everything
    // below behaves exactly like the single-message send this always was.
    final split = splitIntoAlertParts(text);
    final parts = split.parts;

    setState(() {
      _isSending = true;
      _sendingTotal = parts.length;
      _sendingIndex = 0;
    });

    if (split.truncated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            "That alert was too long even split up — sent the first $kAlertMaxParts parts, the rest was cut."),
        duration: Duration(seconds: 6),
      ));
    }

    // Show every part immediately, in the right order, before any of them
    // has actually gone out — same "own message shows first" reasoning a
    // single-part send always used (the msgId isn't known until
    // onSendMessage returns, and waiting on a Bluetooth round trip before
    // the sender even sees their own alert would feel broken), just applied
    // to each part.
    final startIndex = _messages.length;
    final now = DateTime.now();
    setState(() {
      _messages.addAll(parts.map((part) => CommunityMessage(
        sender: widget.myUsername,
        text: part,
        timestamp: now,
        isMe: true,
        isAdmin: true,
      )));
    });
    await _persist();
    _scrollToBottom();

    try {
      // Sequential, not concurrent — admin_ble_hub.dart's
      // broadcastAdminChatMessage queues internally for exactly this
      // reason (two messages can't cycle chunks on the same BLE radio at
      // once without corrupting both), but awaiting each part here in turn
      // also keeps the progress indicator honestly in step with what's
      // actually on the air.
      for (var i = 0; i < parts.length; i++) {
        if (!mounted) return;
        setState(() => _sendingIndex = i + 1);
        await _sendOnePart(parts[i], startIndex + i);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendingTotal = 0;
          _sendingIndex = 0;
        });
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final charsUsed = _controller.text.length;
    final remaining = _maxMsgLen - charsUsed;
    final nearLimit = remaining <= 10;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
        title: Row(
          children: [
            Icon(Icons.campaign, color: colors.primary),
            const SizedBox(width: 8),
            Text(
              'Community Alerts',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontSize: 20, color: colors.primary),
            ),
          ],
        ),
      ),
      body: HopsBackgroundPattern(child: Column(
        children: [
          // ── Messages ──────────────────────────────────────────────────────
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(colors)
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              itemCount: _messages.length,
              itemBuilder: (ctx, i) {
                final msg = _messages[i];
                final showHeader = i == 0 ||
                    _messages[i - 1].sender != msg.sender ||
                    _messages[i - 1].isMe != msg.isMe;
                return _buildBubble(msg, colors,
                    showHeader: showHeader);
              },
            ),
          ),

          // ── Char counter (compose only — nothing to count while reading) ──
          if (widget.amAdmin)
            Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              color: colors.surfaceContainerHighest.withValues(alpha: 0.25),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 12,
                      color: colors.onSurface.withValues(alpha: 0.35)),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _sendingTotal > 1
                          ? 'Sending part $_sendingIndex of $_sendingTotal — long alerts go out as several linked messages'
                          : 'Broadcasts as an official alert to every nearby Hops user',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurface.withValues(alpha: 0.35),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  AnimatedOpacity(
                    opacity: charsUsed > 0 ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      '$charsUsed/$_maxMsgLen',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                        nearLimit ? FontWeight.bold : FontWeight.normal,
                        color: nearLimit
                            ? Colors.redAccent
                            : colors.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Input (admin) / read-only footer (student) ────────────────────
          // The clearance for the floating pill bottom nav (HopsApp's
          // Scaffold uses extendBody: true, so it otherwise sits directly
          // on top of this and swallows every tap meant for it) lives
          // OUTSIDE this bar's own padding, as transparent space, rather
          // than inside it — stuffing it inside the bar's padding pushed
          // the actual content up and left a big dead-looking gap under it
          // within the same shadowed/colored box.
          //
          // navBarPillHeightNotifier now reports the nav area's FULL
          // occupied height, safe-area inset included (see hops_app.dart's
          // bottomNavigationBar). Adding MediaQuery.padding.bottom on top of
          // it here — which this used to do — double-counted that inset on
          // gesture-nav devices and left the bar floating well above the
          // pill instead of sitting just on top of it.
          //
          // The clearance is dropped entirely while the keyboard is up:
          // the Scaffold has already shrunk the body by the keyboard's
          // height, and the bottom nav is underneath the keyboard rather
          // than competing for the same space, so still reserving room for
          // it left a large dead gap between the input and the keyboard.
          ValueListenableBuilder<double>(
            valueListenable: navBarPillHeightNotifier,
            builder: (context, navAreaHeight, child) {
              final keyboardUp = MediaQuery.of(context).viewInsets.bottom > 0;
              return Padding(
                padding: EdgeInsets.only(bottom: keyboardUp ? 0 : navAreaHeight),
                child: child,
              );
            },
            child: widget.amAdmin ? _buildComposer(colors) : _buildReadOnlyFooter(colors),
          ),
        ],
      )),
    );
  }

  Widget _buildComposer(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              maxLength: _maxMsgLen,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Write an alert for everyone nearby…',
                counterText: '',
                filled: true,
                fillColor: colors.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(100),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: _isSending
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Icon(Icons.send,
                color: Colors.white, size: 20),
            style: IconButton.styleFrom(
              backgroundColor: _controller.text.isNotEmpty
                  ? colors.primary
                  : colors.primary.withValues(alpha: 0.3),
              padding: const EdgeInsets.all(12),
            ),
            onPressed:
            _controller.text.isNotEmpty ? _send : null,
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyFooter(ColorScheme colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: colors.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined,
              size: 14, color: colors.onSurface.withValues(alpha: 0.35)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Only Hops admins can post here · hold an alert to report it',
              style: TextStyle(
                fontSize: 12,
                color: colors.onSurface.withValues(alpha: 0.45),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Admin moderation ──────────────────────────────────────────────────────

  /// Replaces a removed message in the thread. Deliberately keeps the
  /// sender's name and timestamp visible: silently vanishing alerts make a
  /// thread impossible to follow and look like a bug, whereas "removed, and
  /// here's why" is both honest and a visible deterrent to everyone else in
  /// the room.
  Widget _buildTombstone(CommunityMessage msg, ColorScheme colors, bool isMe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMe ? 18 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 18),
        ),
        border: Border.all(color: colors.onSurface.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.gavel, size: 13, color: colors.onSurface.withValues(alpha: 0.45)),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              "Removed by an admin — "
              "${kCommunityDeleteReasonLabels[msg.deletedReason] ?? 'breaking the rules'}",
              style: TextStyle(
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
                color: colors.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAdminMessageActions(CommunityMessage msg) {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: colors.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text('"${msg.text}"',
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: colors.onSurface.withValues(alpha: 0.7))),
            ),
            const SizedBox(height: 12),
            // A message this device only ever heard as a broadcast can't be
            // deleted unless it carries the wire identity a deletion is
            // keyed by — true for anything received, and for our own
            // messages once onSendMessage has returned its id.
            if (msg.senderTag != null && msg.msgId != null)
              ListTile(
                leading: Icon(Icons.delete_forever, color: Colors.red.shade700),
                title: Text("Remove for everyone",
                    style: TextStyle(
                        color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                subtitle: Text("Replaced with a reason on every device in range",
                    style: TextStyle(
                        fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55))),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _pickDeleteReason(msg);
                },
              )
            else
              ListTile(
                leading: Icon(Icons.info_outline,
                    color: colors.onSurface.withValues(alpha: 0.4)),
                title: const Text("Can't remove this one"),
                subtitle: Text(
                    "It was saved before removal existed, so there's no id to target.",
                    style: TextStyle(
                        fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55))),
              ),
            if (msg.realUsername != null)
              ListTile(
                leading: Icon(Icons.flag_outlined, color: colors.primary),
                title: const Text("File a report"),
                subtitle: Text("Goes into the Reports queue with the rest",
                    style: TextStyle(
                        fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55))),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  showReportContentSheet(
                    context,
                    contentType: 'chat_message',
                    targetUsername: msg.realUsername,
                    snapshotText: msg.text,
                    contentCreatedAt: msg.timestamp,
                  );
                },
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDeleteReason(CommunityMessage msg) async {
    final colors = Theme.of(context).colorScheme;
    final reason = await showModalBottomSheet<CommunityDeleteReason>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            const Text("Why is it being removed?",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                "This is shown in place of the alert, so everyone who saw it "
                "learns why it went.",
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, color: colors.onSurface.withValues(alpha: 0.55)),
              ),
            ),
            const SizedBox(height: 8),
            ...CommunityDeleteReason.values.map((r) => ListTile(
                  title: Text(kCommunityDeleteReasonLabels[r] ?? r.name),
                  onTap: () => Navigator.pop(sheetCtx, r),
                )),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    await _deleteMessage(msg, reason);
  }

  // Streamlined self-delete — only ever reachable when isMe (see
  // _buildBubble's onLongPress below), i.e. an admin removing their OWN
  // alert. Skips the "why is it being removed" picker entirely: that's a
  // moderation-flavored question that doesn't make sense to ask someone
  // about their own content, and showing "breaking the rules" as the
  // tombstone reason for your own removed message would be actively
  // unfair. Uses the exact same underlying broadcast/apply mechanism as
  // admin moderation (_deleteMessage) — the wire format doesn't
  // distinguish "why," only "what and who."
  Future<void> _deleteOwnMessage(CommunityMessage msg) => _deleteMessage(msg, CommunityDeleteReason.removedBySender);

  Future<void> _deleteMessage(CommunityMessage msg, CommunityDeleteReason reason) async {
    // Mirrored to the server as well as broadcast, so a device that only
    // ever learns about this alert from the catch-up fetch also learns it
    // was withdrawn. Without this, a student whose Bluetooth was off when
    // the alert went out would receive it from the server and never see
    // the retraction — the worst of both paths.
    //
    // Fire-and-forget relative to the radio result below: the broadcast is
    // what the admin is told about, and this failing only costs the
    // catch-up path.
    unawaited(CommunityAlertSync.instance.withdraw(
      senderTag: msg.senderTag ?? '',
      msgId: msg.msgId ?? -1,
      reason: reason.index,
    ));

    final ok = await AdminBleHub.instance.broadcastMessageDeletion(
      senderTag: msg.senderTag!,
      msgId: msg.msgId!,
      reason: reason,
    );

    // Applied locally regardless of the broadcast result. If advertising
    // failed, the admin's own copy still shouldn't keep showing content
    // they've just decided to remove — and the mismatch is reported rather
    // than hidden.
    await _applyDeletion(DecodedCommunityDeletion(
      senderTag: msg.senderTag!,
      msgId: msg.msgId!,
      reason: reason,
    ));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? "Removal broadcast — devices in range will drop it within a few seconds."
          : "Removed here, but the broadcast failed. Check Bluetooth: other devices still have it."),
      duration: const Duration(seconds: 4),
    ));
  }

  // ── Bubble ────────────────────────────────────────────────────────────────

  Widget _buildBubble(
      CommunityMessage msg,
      ColorScheme colors, {
        required bool showHeader,
      }) {
    final isMe = msg.isMe;
    // Every message in this feed is an admin alert now — the fixed red
    // treatment (regardless of light/dark theme or isMe) is what makes an
    // alert read as unmistakably official on every device that receives it.
    final adminColor = Colors.red.shade700;
    return Padding(
      padding: EdgeInsets.only(
        top: showHeader ? 10 : 2,
        bottom: 2,
        left: isMe ? 48 : 0,
        right: isMe ? 0 : 48,
      ),
      child: Row(
        mainAxisAlignment:
        isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            if (showHeader)
              CircleAvatar(
                radius: 15,
                backgroundColor: adminColor.withValues(alpha: 0.15),
                child: Icon(Icons.shield, size: 15, color: adminColor),
              )
            else
              const SizedBox(width: 30),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (showHeader)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 4, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield, size: 11, color: adminColor),
                        const SizedBox(width: 3),
                        Text(
                          isMe ? "You (Admin)" : msg.sender,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: adminColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (msg.isDeleted)
                  _buildTombstone(msg, colors, isMe)
                else
                GestureDetector(
                  // Three cases, in priority order:
                  //  1. Your own message (only ever possible for the admin
                  //     who sent it — students can't post here at all) —
                  //     a direct, no-questions-asked delete. See
                  //     _deleteOwnMessage's comment for why this skips the
                  //     moderation reason picker.
                  //  2. Someone ELSE's message, viewed by an admin — full
                  //     moderation (remove for everyone with a reason, or
                  //     report).
                  //  3. Someone else's message, viewed by a student —
                  //     reporting only.
                  onLongPress: (isMe && msg.senderTag != null && msg.msgId != null)
                      ? () => _deleteOwnMessage(msg)
                      : widget.amAdmin
                          ? () => _showAdminMessageActions(msg)
                          : (msg.realUsername == null)
                              ? null
                              : () => showReportContentSheet(
                                    context,
                                    contentType: 'chat_message',
                                    targetUsername: msg.realUsername,
                                    snapshotText: msg.text,
                                    contentCreatedAt: msg.timestamp,
                                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: adminColor,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(isMe ? 18 : 4),
                        bottomRight: Radius.circular(isMe ? 4 : 18),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      msg.text,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding:
                  const EdgeInsets.only(top: 3, left: 4, right: 4),
                  child: Text(
                    _fmtTime(msg.timestamp),
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.onSurface.withValues(alpha: 0.32),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isMe) const SizedBox(width: 6),
        ],
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────

  Widget _buildEmptyState(ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined,
                size: 64, color: colors.primary.withValues(alpha: 0.18)),
            const SizedBox(height: 18),
            Text(
              'Community Alerts',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: colors.onSurface.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.amAdmin
                  ? 'No alerts sent yet. Compose one below and it broadcasts '
                      'instantly, over Bluetooth, to every nearby Hops user.'
                  : 'Official alerts from Hops admins appear here the moment '
                      "they're sent — broadcast over Bluetooth, no signal needed.",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: colors.onSurface.withValues(alpha: 0.32),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
