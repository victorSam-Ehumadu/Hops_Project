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
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/main.dart' show navBarPillHeightNotifier;

class CommunityMessage {
  final String sender;
  final String text;
  final DateTime timestamp;
  final bool isMe;

  const CommunityMessage({
    required this.sender,
    required this.text,
    required this.timestamp,
    required this.isMe,
  });

  Map<String, dynamic> toJson() => {
    'sender': sender,
    'text': text,
    'ts': timestamp.millisecondsSinceEpoch,
    'isMe': isMe,
  };

  factory CommunityMessage.fromJson(Map<String, dynamic> j) =>
      CommunityMessage(
        sender: j['sender'] as String,
        text: j['text'] as String,
        timestamp:
        DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        isMe: j['isMe'] as bool,
      );
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
  final Future<void> Function(String message) onSendMessage;
  final String myUsername;
  // This device's own rotating-ID seed — used only to recognize (and skip)
  // our own re-broadcast chunks as they cycle past our own scanner.
  final List<int>? mySeed;
  // Known contacts' seeds — resolves an incoming sender token to a real
  // name; unresolved senders show as anonymous. Same mechanism as Radar.
  final Map<String, List<int>> contactSeeds;

  const CommunityChat({
    super.key,
    required this.radarStream,
    required this.onSendMessage,
    required this.myUsername,
    this.mySeed,
    this.contactSeeds = const {},
  });

  @override
  State<CommunityChat> createState() => _CommunityChatState();
}

class _CommunityChatState extends State<CommunityChat> {
  static const _prefsKey = 'community_messages_v1';
  static const int _maxStored = 100;
  // Generous cap safely under the worst-case chunk capacity
  // (kCommunityMaxChunks × per-chunk text budget, see hops_constants.dart).
  // Longer messages just take a few extra seconds to fully arrive, spread
  // across multiple broadcast chunks, instead of hitting a hard wall.
  static const int _maxMsgLen = 180;

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

  String? _resolveSenderToken(String token) {
    for (final entry in widget.contactSeeds.entries) {
      if (matchesRotatingToken(entry.value, token)) return entry.key;
    }
    return null;
  }

  void _listenToRadar() {
    _streamSub = widget.radarStream.listen((results) {
      bool updated = false;
      final now = DateTime.now();

      for (final r in results) {
        final mfgBytes = r.advertisementData.manufacturerData[kCommunityManufacturerId];
        if (mfgBytes == null) continue;
        final decoded = decodeCommunityChatChunk(mfgBytes);
        if (decoded == null || decoded.senderToken.isEmpty) continue;

        // Skip our own broadcasts — recognized via our own rotating seed
        // rather than a plain string match, since the tag now changes
        // every 15 minutes instead of being a fixed username fragment.
        final mySeed = widget.mySeed;
        if (mySeed != null && matchesRotatingToken(mySeed, decoded.senderToken)) continue;

        final msgKey = '${decoded.senderToken}:${decoded.msgId}';
        if (_completedMsgKeys.containsKey(msgKey)) continue; // already shown

        final buffer = _pendingChunks.putIfAbsent(
            msgKey, () => _ChunkBuffer(decoded.totalChunks));
        buffer.chunks[decoded.chunkIndex] = decoded.text;
        buffer.lastSeen = now;

        if (buffer.isComplete) {
          _pendingChunks.remove(msgKey);
          _completedMsgKeys[msgKey] = now;
          // Only a known contact's real name is ever shown — anyone else's
          // token resolves to nothing, so their message stays anonymous.
          final resolved = _resolveSenderToken(decoded.senderToken);
          _messages.add(CommunityMessage(
            sender: resolved ??
                'Anonymous #${decoded.senderToken.substring(0, decoded.senderToken.length < 4 ? decoded.senderToken.length : 4)}',
            text: buffer.reassembled,
            timestamp: now,
            isMe: false,
          ));
          updated = true;
        }
      }

      // Drop buffers for messages we've stopped hearing chunks for (some
      // were missed and the sender's cycle has moved on or finished).
      final staleCutoff = now.subtract(const Duration(seconds: 15));
      _pendingChunks.removeWhere((_, buf) => buf.lastSeen.isBefore(staleCutoff));

      // Forget completed keys after a while — msgId is only 0-255 per
      // sender, and without this a wrapped-around id would be mistaken
      // for the old message and silently dropped forever.
      final forgetCutoff = now.subtract(const Duration(seconds: 90));
      _completedMsgKeys.removeWhere((_, seenAt) => seenAt.isBefore(forgetCutoff));

      if (updated) {
        _persist();
        if (mounted) {
          setState(() {});
          _scrollToBottom();
        }
      }
    });
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    _controller.clear();
    setState(() => _isSending = true);

    // Show own message immediately.
    setState(() => _messages.add(CommunityMessage(
      sender: widget.myUsername,
      text: text,
      timestamp: DateTime.now(),
      isMe: true,
    )));
    await _persist();
    _scrollToBottom();

    try {
      await widget.onSendMessage(text);
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
        backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
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
            color: colors.surfaceContainerHighest.withOpacity(0.25),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 12,
                    color: colors.onSurface.withOpacity(0.35)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Broadcast to all nearby Hops users',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurface.withOpacity(0.35),
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
                          : colors.onSurface.withOpacity(0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Input ─────────────────────────────────────────────────────────
          // The clearance for the floating pill bottom nav (HopsApp's
          // Scaffold uses extendBody: true, so it otherwise sits directly
          // on top of this field and swallows every tap meant for it — see
          // hops_constants.dart's kFloatingNavClearance) lives OUTSIDE the
          // input bar's own padding, as transparent space, rather than
          // inside it — stuffing it inside the bar's padding pushed the
          // actual text field up and left a big dead-looking gap under it
          // within the same shadowed/colored box.
          //
          // kFloatingNavClearance itself is sized generously (with extra
          // room for larger text-scale nav labels) since it's shared with
          // other spots that just need "don't get covered." This bar is a
          // single fixed-height row with nothing below it, so it can safely
          // sit tighter — trimmed down so it hugs just above the pill
          // instead of floating with a big gap underneath it.
          //
          // Was a fixed offset hand-tuned down from kFloatingNavClearance
          // (that constant is deliberately oversized "don't get covered"
          // padding meant for scrollable lists, not a tight fit) — kept
          // coming back as "still too high" because it was still a guess.
          // Uses the pill's real measured height instead — see
          // navBarPillHeightNotifier's doc comment in main.dart.
          ValueListenableBuilder<double>(
            valueListenable: navBarPillHeightNotifier,
            builder: (context, pillHeight, child) => Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + pillHeight + 6),
              child: child,
            ),
            child: Container(
              padding: const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 10),
              decoration: BoxDecoration(
                color: colors.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
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
                        : colors.primary.withOpacity(0.3),
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

  // ── Bubble ────────────────────────────────────────────────────────────────

  Widget _buildBubble(
      CommunityMessage msg,
      ColorScheme colors, {
        required bool showHeader,
      }) {
    final isMe = msg.isMe;
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
                backgroundColor: colors.primary.withOpacity(0.12),
                child: Text(
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
                if (!isMe && showHeader)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 4),
                    child: Text(
                      msg.sender,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: colors.primary.withOpacity(0.75),
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: isMe
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isMe ? 18 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    msg.text,
                    style: TextStyle(
                      color: isMe ? Colors.white : colors.onSurface,
                      fontSize: 14,
                      height: 1.3,
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
                      color: colors.onSurface.withOpacity(0.32),
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
                size: 64, color: colors.primary.withOpacity(0.18)),
            const SizedBox(height: 18),
            Text(
              'Community Chat',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: colors.onSurface.withOpacity(0.45),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Messages broadcast over Bluetooth to every nearby Hops user. '
                  'No pairing needed — just type and send.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: colors.onSurface.withOpacity(0.32),
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
