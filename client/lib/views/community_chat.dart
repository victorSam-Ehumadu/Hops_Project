// lib/views/community_chat.dart
//
// Dedup mechanism is identical to VibeCheckPage:
// _processedNames is a Set<String> keyed by the FULL advertisement name
// (e.g. "CM:alic:meet at gate 2"). A Set can only contain each string once,
// so the same packet received 1000 times is processed exactly once.
// No timers, no MACs, no async — just a Set.contains() check.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static const int _maxMsgLen = 21; // CM:(4)sender:(1):(21)msg = 29 bytes ✓
  static const int _userLen = 4;

  List<CommunityMessage> _messages = [];
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription? _streamSub;
  bool _isSending = false;

  // ── Dedup — IDENTICAL to VibeCheckPage._communityReports ─────────────────
  // Key = full advertisement name, e.g. "CM:alic:meet at gate 2".
  // A Set<String> can hold each value exactly once. The scanner may deliver
  // the same advertisement thousands of times — Set.contains() catches all
  // of them after the first. No timers, no MACs, no async removal needed.
  final Set<String> _processedNames = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _listenToRadar(); // same structure as VibeCheckPage.initState
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

  // ── Radar listener — same structure as VibeCheckPage ─────────────────────

  void _listenToRadar() {
    _streamSub = widget.radarStream.listen((results) {
      bool updated = false;

      for (final r in results) {
        final advName = r.advertisementData.advName;
        if (!advName.startsWith('CM:')) continue;

        // ── The VibeCheck dedup trick ──────────────────────────────────────
        // If this exact advertisement name is already in the Set, skip.
        // The Set holds it once no matter how many scan results deliver it.
        if (_processedNames.contains(advName)) continue;
        _processedNames.add(advName);

        // Parse "CM:sender:text"  (text may contain colons)
        final payload = advName.substring(3);
        final sep = payload.indexOf(':');
        if (sep <= 0 || sep >= payload.length - 1) continue;

        final sender = payload.substring(0, sep);
        final text = payload.substring(sep + 1);
        if (sender.isEmpty || text.isEmpty) continue;

        // Skip own advertisements
        if (sender == _adUserCm(widget.myUsername)) continue;

        _messages.add(CommunityMessage(
          sender: sender,
          text: text,
          timestamp: DateTime.now(),
          isMe: false,
        ));
        updated = true;
      }

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

    // Pre-register our own advertisement name in the Set BEFORE advertising
    // starts. If our own scanner picks it up, Set.contains() catches it
    // immediately — zero race window, same trick as the listener above.
    final ownAdvName = 'CM:${_adUserCm(widget.myUsername)}:$text';
    _processedNames.add(ownAdvName);

    setState(() => _isSending = true);

    // Show own message immediately
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