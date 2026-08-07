// lib/views/community_chat.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Model ───────────────────────────────────────────────────────────────────

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

// ─── Widget ──────────────────────────────────────────────────────────────────

class CommunityChat extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Future<void> Function(String message) onSendMessage;
  final String myUsername;

  const CommunityChat({
    super.key,
    required this.radarStream,
    required this.onSendMessage,
    required this.myUsername,
  });

  @override
  State<CommunityChat> createState() => _CommunityChatState();
}

class _CommunityChatState extends State<CommunityChat> {
  static const _prefsKey = 'community_messages_v1';
  static const int _maxStored = 100;

  // ── BLE packet budget ─────────────────────────────────────────────────────
  // Scan-response = 31 bytes. Name header = 2 bytes → name ≤ 29 chars.
  // Format: "CM:" (3) + sender (4) + ":" (1) + message (21) = 29 ✓
  static const int _maxMsgLen = 21;
  static const int _userLen = 4;

  List<CommunityMessage> _messages = [];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription? _radarSub;
  bool _isSending = false;

  // ── Deduplication ─────────────────────────────────────────────────────────
  //
  // Key  : "$sender4|$text"  — content-only, no device MAC.
  //        Using the MAC (remoteId) is unreliable on Android 12+ because
  //        BLE uses randomised addresses that can change between scan windows.
  //        Content-keying is stable: same sender + same text = same key.
  //
  // Value: DateTime of FIRST appearance.
  //
  // A packet is a duplicate if the same key appeared within the last 30 s.
  // 30 s > the 8-second advertising window, so every message is processed
  // exactly once regardless of how many scan cycles overlap with that window.
  //
  // Own-message pre-population: when WE send, we immediately insert the key
  // into the map. Any bounce-back from our own scanner is therefore seen as
  // a duplicate and silently dropped — with zero race-window.
  final Map<String, DateTime> _seen = {};
  Timer? _pruneTimer;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _listenToRadar();
    _controller.addListener(() => setState(() {}));

    // Prune stale entries every minute so the map stays small.
    _pruneTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final cutoff =
      DateTime.now().subtract(const Duration(seconds: 35));
      _seen.removeWhere((_, t) => t.isBefore(cutoff));
    });
  }

  @override
  void dispose() {
    _radarSub?.cancel();
    _pruneTimer?.cancel();
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

  // ── BLE receiving ─────────────────────────────────────────────────────────

  void _listenToRadar() {
    _radarSub = widget.radarStream.listen((results) {
      final now = DateTime.now();

      for (final r in results) {
        final name = r.advertisementData.advName;
        if (!name.startsWith('CM:')) continue;

        // Parse "CM:sender:text"  (text may contain colons)
        final payload = name.substring(3);
        final sep = payload.indexOf(':');
        if (sep <= 0 || sep >= payload.length - 1) continue;

        final sender = payload.substring(0, sep);
        final text = payload.substring(sep + 1);
        if (sender.isEmpty || text.isEmpty) continue;

        // Fast-path: drop own advertisements
        if (sender == _adUserCm(widget.myUsername)) continue;

        // Content-keyed dedup — immune to randomised BLE MACs
        final key = '$sender|$text';
        final firstSeen = _seen[key];
        if (firstSeen != null &&
            now.difference(firstSeen).inSeconds < 30) {
          continue; // duplicate within the 30-second window
        }
        _seen[key] = now;

        final msg = CommunityMessage(
          sender: sender,
          text: text,
          timestamp: now,
          isMe: false,
        );

        if (mounted) {
          setState(() => _messages.add(msg));
          _persist();
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

    // Pre-populate the dedup map NOW — before the advertisement starts —
    // so any bounce-back the scanner picks up is treated as a duplicate
    // and silently dropped. No race window.
    final ownKey = '${_adUserCm(widget.myUsername)}|$text';
    _seen[ownKey] = DateTime.now();

    setState(() => _isSending = true);

    // Show own message immediately (optimistic)
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

  /// 4-char truncation for CM: advertisement sender field.
  /// Must match _adUserCm in hops_app.dart.
  String _adUserCm(String u) =>
      u.length > _userLen ? u.substring(0, _userLen) : u;

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
    final nearLimit = remaining <= 5;

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
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withOpacity(0.2),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              children: [
                Icon(Icons.wifi_tethering,
                    size: 11, color: colors.tertiaryContainer),
                const SizedBox(width: 4),
                Text(
                  'BLE Broadcast',
                  style: TextStyle(
                    color: colors.tertiaryContainer,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
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
                      fontWeight: nearLimit
                          ? FontWeight.bold
                          : FontWeight.normal,
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
          Container(
            padding: const EdgeInsets.only(
                left: 16, right: 8, top: 10, bottom: 24),
            decoration: BoxDecoration(
              color: colors.surface.withOpacity(0.6),
              border: Border(
                  top: BorderSide(
                      color: colors.outline.withOpacity(0.1))),
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
                      fillColor: Colors.white.withOpacity(0.7),
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
                        strokeWidth: 2,
                        color: Colors.white),
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
        ],
      ),
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
                    padding:
                    const EdgeInsets.only(bottom: 3, left: 4),
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
                      bottomLeft:
                      Radius.circular(isMe ? 18 : 4),
                      bottomRight:
                      Radius.circular(isMe ? 4 : 18),
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
                      color:
                      isMe ? Colors.white : colors.onSurface,
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                      top: 3, left: 4, right: 4),
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
                size: 64,
                color: colors.primary.withOpacity(0.18)),
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
              'Messages broadcast over BLE to every nearby Hops user. '
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