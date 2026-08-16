// lib/views/community_chat.dart
//
// Wire format v2: messages ride in BLE manufacturer data (scan response),
// chunked and reassembled — see hops_constants.dart for the byte-level
// protocol and hops_app.dart's _advertiseCommunityMessage for the sender
// side. Dedup here works at two levels: an in-flight reassembly buffer per
// (sender, msgId) while chunks are still arriving, and a short-lived
// "already shown" set once a message is complete, so the sender's own
// repeated re-broadcast of the same chunks during its cycle doesn't
// re-add the message every time it's picked up again.

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

class CommunityMessage {
  final String sender;
  final String text;
  final DateTime timestamp;
  final bool isMe;
  // True for a message sent by an admin (either received and resolved via
  // KeyDirectory, or this device's own outgoing message when amAdmin is
  // set — see CommunityChat.amAdmin) — drives the distinct bubble styling
  // in _buildBubble.
  final bool isAdmin;

  // The sender's REAL account name, resolved from the wire tag. Kept
  // separate from [sender] (which is what's actually shown) because the
  // student app deliberately displays a contact's name or an anonymous
  // label instead — see CommunityChat.showRealNames. Reporting must use
  // this one: a report filed against the displayed string named an
  // account that doesn't exist, and the admin app's "Send warning" then
  // failed with "no account by that name exists".
  //
  // Null when this device couldn't match the tag to any cached account
  // (directory never synced, or synced before that account existed) — the
  // report UI treats that as "not reportable" rather than sending a name
  // the server will reject.
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
  /// blank Community Chat rather than one odd message.
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

class CommunityChat extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  /// Sends the message over BLE and returns the 6-bit msgId it was
  /// broadcast under, or null if the sender doesn't track one.
  ///
  /// The id comes back so this device's own copy can be tagged with the
  /// same wire identity everyone else keys it by — without that, an admin
  /// deletion removed the message from every device except the one that
  /// posted it, which is the device whose author most needs to see it go.
  final Future<int?> Function(String message) onSendMessage;
  final String myUsername;

  // True when this is the tab currently on screen. Every tab in HopsApp's
  // PageView stays mounted whether or not it's selected, so `mounted` says
  // nothing about whether the user is actually looking at this — which is
  // exactly what decides between "show a live message" and "raise a badge
  // and a notification". Defaults true for standalone use (the admin app
  // shows this as a whole tab of its own).
  final bool isVisible;

  // Whether to DISPLAY senders' real account names.
  //
  // The wire always carries the real (truncated) username — moderation is
  // impossible without it, since a report has to name an account an admin
  // can actually act on. But showing it to every student nearby is a
  // different question, and the answer is no: students see a known
  // contact's name, or an anonymous label for everyone else, exactly as
  // before. Only the admin app sets this true.
  //
  // Worth being clear-eyed that this is a presentation choice, not a
  // privacy guarantee — the username is on the air either way, and anyone
  // running a modified client could read it. What it does preserve is the
  // social property of the feature (you aren't identified to the room by
  // default) without giving up the accountability admins need.
  final bool showRealNames;

  // True when this instance is running inside the Admin app (see
  // admin_community_chat_tab.dart) — marks this device's own outgoing
  // messages as admin-styled locally, and switches the own-broadcast skip
  // check in _listenToRadar to match on truncated username instead of a
  // rotating seed, since admin messages aren't sent with one. Received
  // messages are marked admin/not independent of this flag (that comes
  // from the wire — see DecodedCommunityChunk.isAdmin); this only affects
  // how OUR OWN messages are labeled/skipped.
  final bool amAdmin;

  const CommunityChat({
    super.key,
    required this.radarStream,
    required this.onSendMessage,
    required this.myUsername,
    this.amAdmin = false,
    this.isVisible = true,
    this.showRealNames = false,
    this.contactSeeds = const {},
  });

  // Known contacts' rotating-ID seeds. Community Chat no longer identifies
  // senders by rotating token (the wire tag is a username now), but a
  // *contact's* name is still shown rather than an anonymous label — and
  // deciding "is this sender someone I've paired with" still means
  // checking whether their name is one of these keys.
  final Map<String, List<int>> contactSeeds;

  @override
  State<CommunityChat> createState() => _CommunityChatState();
}

class _CommunityChatState extends State<CommunityChat> {
  static const _prefsKey = 'community_messages_v1';
  static const int _maxStored = 100;
  // Hard capacity of the v3 advertisement-name format is
  // kCommunityNameMaxChunks × kCommunityNameTextBudget = 8 × 14 = 112
  // *bytes* (see hops_constants.dart). Capped a little under that in
  // characters, since a non-ASCII character costs more than one byte and
  // anything over the byte ceiling is silently truncated by
  // splitCommunityMessage rather than rejected.
  // Derived, not hand-picked: the most that can actually fit on the wire is
  // kCommunityNameMaxChunks × kCommunityNameTextBudget. It was hard-coded at
  // 105 against a 14-byte chunk budget; when that budget changed the two
  // silently disagreed and splitCommunityMessage quietly dropped the
  // overflow, so anything past the real limit was truncated mid-sentence
  // with the counter still saying there was room.
  static const int _maxMsgLen =
      kCommunityNameMaxChunks * kCommunityNameTextBudget;

  List<CommunityMessage> _messages = [];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription? _streamSub;
  bool _isSending = false;

  final Map<String, _ChunkBuffer> _pendingChunks = {}; // key: "sender:msgId"
  final Map<String, DateTime> _completedMsgKeys = {}; // msgKey -> shown-at

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _listenToRadar();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
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
  // directory and adds the completed message. Async (KeyDirectory reads
  // from SharedPreferences on first use), so it's kept outside the
  // synchronous per-batch loop in _listenToRadar and manages its own
  // setState/_persist/scroll rather than folding into that loop's shared
  // `updated` flag.
  //
  // [isAdmin] comes from the wire prefix, but is only *trusted* if the
  // resolved account is actually cached with role 'admin' — otherwise
  // anyone could style their message as official just by using the CA:
  // prefix. An unresolvable admin-claiming tag is shown as an ordinary
  // message, not an admin one.
  Future<void> _resolveSenderAndAdd(
      String tag, int msgId, String text, DateTime now, bool claimsAdmin) async {
    // Permanent guard against re-adding a message already in the list,
    // independent of _completedMsgKeys' 90-second memory.
    //
    // This is the actual fix for "messages keep repeating": the 90-second
    // window only ever existed to skip re-processing chunks still arriving
    // during a message's own active broadcast cycle (which finishes in
    // well under 90s — see splitCommunityMessage's timing). Once that
    // window lapsed, a chunk set for the SAME message arriving again —
    // from Android's BLE scan cache replaying a device's last-seen
    // advertisement on a fresh scan (e.g. after tapping Rescan), or a
    // sender's peripheral stack not fully releasing a stopped
    // advertisement before the next one starts — was treated as brand
    // new and reassembled into a second, duplicate bubble. Checking
    // against what's actually on screen has no expiry, so a stale
    // redelivery can't produce a duplicate no matter how late it arrives.
    if (_messages.any((m) => m.senderTag == tag && m.msgId == msgId)) return;

    final candidates = await KeyDirectory.candidatesForTruncatedUsername(tag);
    String? resolvedName;
    var confirmedAdmin = false;
    for (final candidate in candidates) {
      if (claimsAdmin && candidate.value.role != 'admin') continue;
      resolvedName = candidate.key;
      confirmedAdmin = claimsAdmin && candidate.value.role == 'admin';
      break;
    }

    if (!mounted) return;

    // What to actually SHOW. Admins see the real account name; students
    // see a contact's name if this is someone they've paired with, and an
    // anonymous label otherwise — see showRealNames' doc comment.
    final isKnownContact =
        resolvedName != null && widget.contactSeeds.containsKey(resolvedName);
    final String displayName;
    if (widget.showRealNames && resolvedName != null) {
      displayName = resolvedName;
    } else if (isKnownContact) {
      displayName = resolvedName;
    } else if (confirmedAdmin) {
      // An admin's message is meant to be recognizable as official even in
      // the student app — that's the entire point of the separate tier.
      displayName = resolvedName ?? 'Admin';
    } else {
      // Hashed, NOT the raw tag — the tag is the sender's username now, so
      // printing it here would have made "Anonymous #Kwame123". See
      // anonymousLabelFor.
      displayName = 'Anonymous #${anonymousLabelFor(tag)}';
    }

    // Badge + system notification — but only when this screen isn't the
    // thing being looked at right now. Community Chat lives in a PageView
    // inside HopsApp, so "mounted" isn't enough to tell: every tab stays
    // mounted regardless of which one is on screen. widget.isVisible is
    // what HopsApp uses to say "this is the selected tab", and the
    // lifecycle check covers the app being backgrounded entirely.
    final looking = widget.isVisible &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!looking) {
      UnreadTracker.instance.mark(UnreadSource.communityChat);
      NotificationService.showCommunityMessageNotification(
        sender: displayName,
        message: text,
      );
    }

    setState(() {
      _messages.add(CommunityMessage(
        sender: displayName,
        text: text,
        timestamp: now,
        isMe: false,
        isAdmin: confirmedAdmin,
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

        // Skip our own broadcasts — the tag is now the sender's truncated
        // username for everyone (student and admin alike), so this is one
        // plain comparison rather than the two-branch check the rotating-
        // token version needed.
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
          // this device's contacts — so a name shows for everyone nearby,
          // not only people already paired with. See _resolveSenderAndAdd.
          _resolveSenderAndAdd(decoded.senderTag, decoded.msgId,
              buffer.reassembled, now, decoded.isAdmin);
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

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    _controller.clear();
    setState(() => _isSending = true);

    // Show own message immediately, before it's been broadcast — the msgId
    // isn't known until onSendMessage returns, and waiting for a Bluetooth
    // round trip before the sender sees their own message would feel broken.
    final index = _messages.length;
    setState(() => _messages.add(CommunityMessage(
      sender: widget.myUsername,
      text: text,
      timestamp: DateTime.now(),
      isMe: true,
      isAdmin: widget.amAdmin,
    )));
    await _persist();
    _scrollToBottom();

    try {
      final msgId = await widget.onSendMessage(text);
      // Null means the broadcast never started. Said out loud, because the
      // message is already sitting in this device's own list looking sent —
      // which is exactly how a message that reached nobody passed for a
      // delivered one.
      if (msgId == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't broadcast — check Bluetooth is on, then try again."),
          duration: Duration(seconds: 5),
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
            isAdmin: mine.isAdmin,
            realUsername: mine.realUsername,
            senderTag: tag,
            msgId: msgId,
          );
          await _persist();
        }
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
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
              'Community Chat',
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

          // ── Info / char counter ───────────────────────────────────────────
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
                    'Broadcast to all nearby Hops users · hold a message to report it',
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

          // ── Input ─────────────────────────────────────────────────────────
          // The clearance for the floating pill bottom nav (HopsApp's
          // Scaffold uses extendBody: true, so it otherwise sits directly
          // on top of this field and swallows every tap meant for it) lives
          // OUTSIDE the input bar's own padding, as transparent space,
          // rather than inside it — stuffing it inside the bar's padding
          // pushed the actual text field up and left a big dead-looking gap
          // under it within the same shadowed/colored box.
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
          // it left a large dead gap between the text field and the
          // keyboard.
          ValueListenableBuilder<double>(
            valueListenable: navBarPillHeightNotifier,
            builder: (context, navAreaHeight, child) {
              final keyboardUp = MediaQuery.of(context).viewInsets.bottom > 0;
              return Padding(
                padding: EdgeInsets.only(bottom: keyboardUp ? 0 : navAreaHeight),
                child: child,
              );
            },
            child: Container(
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
                      hintText: 'Message everyone nearby…',
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
            ),
          ),
        ],
      )),
    );
  }

  // ── Admin moderation ──────────────────────────────────────────────────────

  /// Replaces a removed message in the thread. Deliberately keeps the
  /// sender's name and timestamp visible: silently vanishing messages make
  /// a conversation impossible to follow and look like a bug, whereas
  /// "removed, and here's why" is both honest and a visible deterrent to
  /// everyone else in the room.
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
                "This is shown in place of the message, so everyone who saw it "
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
    // Admin messages get their own fixed color regardless of light/dark
    // theme or isMe — the whole point is that an admin's message reads as
    // unmistakably distinct from an ordinary bubble, on every device that
    // receives it, not just a tint of whichever theme happens to be active.
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
                backgroundColor: msg.isAdmin
                    ? adminColor.withValues(alpha: 0.15)
                    : colors.primary.withValues(alpha: 0.12),
                child: msg.isAdmin
                    ? Icon(Icons.shield, size: 15, color: adminColor)
                    : Text(
                        msg.sender.isNotEmpty
                            ? msg.sender[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colors.primary,
                        ),
                      ),
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
                if (showHeader && (!isMe || msg.isAdmin))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 4, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg.isAdmin) ...[
                          Icon(Icons.shield, size: 11, color: adminColor),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          isMe ? "You (Admin)" : msg.sender,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: msg.isAdmin ? adminColor : colors.primary.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (msg.isDeleted)
                  _buildTombstone(msg, colors, isMe)
                else
                GestureDetector(
                  // In the admin app a long-press offers moderation
                  // (remove for everyone, or report through the normal
                  // flow); in the student app it's reporting only.
                  //
                  // Reporting your own message makes no sense — only
                  // wired up for messages from someone else.
                  // Reports carry realUsername, never the displayed name —
                  // the display is deliberately anonymized in the student
                  // app, and an admin can't act on "Anonymous #ab12".
                  // Unresolvable senders can't be reported at all rather
                  // than filing a report the server will reject.
                  onLongPress: widget.amAdmin
                      ? () => _showAdminMessageActions(msg)
                      : (isMe || msg.realUsername == null)
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
                      color: msg.isAdmin
                          ? adminColor
                          : (isMe ? colors.primary : colors.surfaceContainerHighest),
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
                      style: TextStyle(
                        color: (isMe || msg.isAdmin) ? Colors.white : colors.onSurface,
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
              'Community Chat',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: colors.onSurface.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Messages broadcast over Bluetooth to every nearby Hops user. '
                  'No pairing needed — just type and send.',
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
