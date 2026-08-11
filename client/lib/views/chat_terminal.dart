// chat_terminal.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/services/hops_chat_service.dart';
import 'package:client/views/contact_profile_screen.dart';

class IndividualChatTerminalView extends StatefulWidget {
  final String peerName;
  // Threaded down to ContactProfileScreen when the app-bar avatar is
  // tapped — the actual contacts state (_addedFriends etc.) lives in
  // HopsApp, not here, so deletion has to be delegated back up to it.
  final Future<void> Function(String peerUsername) onDeleteContact;

  const IndividualChatTerminalView({
    super.key,
    required this.peerName,
    required this.onDeleteContact,
  });

  @override
  State<IndividualChatTerminalView> createState() =>
      _IndividualChatTerminalViewState();
}

class _IndividualChatTerminalViewState
    extends State<IndividualChatTerminalView> {
  List<Map<String, dynamic>> messageThreadsList = [];
  final TextEditingController _msgInputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String myPersonalUsernameLabel = "User_Vic";
  Timer? _refreshTimer;

  HopsChatService? _chatService;
  ChatConnectionState _connState = ChatConnectionState.connecting;

  // The peer's avatar/bio, learned only by direct exchange over this same
  // connection — see HopsChatService.sendProfile. _peerAvatarPath reflects
  // whatever's cached from a previous chat until (if) a fresh one arrives.
  String? _peerAvatarPath;

  @override
  void initState() {
    super.initState();
    _init();

    // Light periodic fallback — the real-time path is _chatService's
    // onMessageReceived callback below, but this also picks up rows
    // written by the older pairing-code contact log while the screen
    // is open.
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _loadPeerMessageLogs());
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    myPersonalUsernameLabel = prefs.getString('my_username') ?? 'User_Vic';

    // Show whatever avatar we already cached from a previous chat with
    // this peer, if any, before a fresh exchange (re)confirms it.
    final cachedProfile = await DatabaseHelper.instance.getContactProfile(widget.peerName);
    _peerAvatarPath = cachedProfile?[DatabaseHelper.cpColAvatarPath] as String?;
    if (mounted) setState(() {});

    await _loadPeerMessageLogs();

    _chatService = HopsChatService(
      myUsername: myPersonalUsernameLabel,
      peerUsername: widget.peerName,
      onMessageReceived: _handleIncomingMessage,
      onProfileReceived: _handlePeerProfileReceived,
      onStateChanged: (state) {
        if (!mounted) return;
        setState(() => _connState = state);
        if (state == ChatConnectionState.connected) {
          // Anything sent while the peer wasn't reachable is still sitting
          // undelivered — now that we're connected, try again instead of
          // leaving it stranded until the user notices and re-sends by hand.
          _flushUndeliveredMessages();
          _sendMyProfile();
        }
      },
    );
    await _chatService!.connect();
  }

  Future<void> _sendMyProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final bio = prefs.getString('bio') ?? '';
    final avatarPath = prefs.getString('avatar_path');
    Uint8List? avatarBytes;
    if (avatarPath != null) {
      try {
        final file = File(avatarPath);
        if (await file.exists()) avatarBytes = await file.readAsBytes();
      } catch (_) {
        // No avatar to send — not fatal, bio still goes out below.
      }
    }
    await _chatService?.sendProfile(bio: bio, avatarBytes: avatarBytes);
  }

  Future<void> _handlePeerProfileReceived(String bio, Uint8List? avatarBytes) async {
    String? savedAvatarPath;
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/contact_avatar_${widget.peerName}.jpg');
        await file.writeAsBytes(avatarBytes, flush: true);
        savedAvatarPath = file.path;
      } catch (_) {
        // Keep whatever avatar (if any) was already cached rather than
        // losing it over a failed write.
        savedAvatarPath = _peerAvatarPath;
      }
    }
    await DatabaseHelper.instance.upsertContactProfile(
      widget.peerName,
      avatarPath: savedAvatarPath,
      bio: bio,
    );
    if (mounted) setState(() => _peerAvatarPath = savedAvatarPath);
  }

  Future<void> _retryConnect() async {
    setState(() => _connState = ChatConnectionState.connecting);
    await _chatService?.connect();
  }

  Future<void> _flushUndeliveredMessages() async {
    final pending = await DatabaseHelper.instance
        .getUndeliveredMessagesForPeer(widget.peerName, myPersonalUsernameLabel);
    if (pending.isEmpty) return;

    for (final row in pending) {
      final id = row[DatabaseHelper.columnId] as String;
      final text = row[DatabaseHelper.columnMessage] as String;
      final delivered = await _chatService?.sendMessage(text) ?? false;
      if (!delivered) break; // stay in order — don't skip ahead on failure
      await DatabaseHelper.instance.markMessageDelivered(id);
    }
    await _loadPeerMessageLogs();
  }

  Future<void> _handleIncomingMessage(String message) async {
    final incomingPayload = {
      DatabaseHelper.columnId: const Uuid().v4(),
      DatabaseHelper.columnMessage: message,
      DatabaseHelper.columnSenderId: widget.peerName,
      DatabaseHelper.columnPeerId: widget.peerName,
      DatabaseHelper.columnIsForMe: 1,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnDelivered: 1,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertMessage(incomingPayload);
    await _loadPeerMessageLogs();
  }

  Future<void> _loadPeerMessageLogs() async {
    final data = await DatabaseHelper.instance.getMessagesForPeer(widget.peerName);
    if (!mounted) return;
    setState(() => messageThreadsList = data);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _msgInputController.text.trim();
    if (text.isEmpty) return;
    _msgInputController.clear();

    final id = const Uuid().v4();
    final outgoingPayload = {
      DatabaseHelper.columnId: id,
      DatabaseHelper.columnMessage: text,
      DatabaseHelper.columnSenderId: myPersonalUsernameLabel,
      DatabaseHelper.columnPeerId: widget.peerName,
      DatabaseHelper.columnIsForMe: 0,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnDelivered: 0,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertMessage(outgoingPayload);
    await _loadPeerMessageLogs();

    final delivered = await _chatService?.sendMessage(text) ?? false;
    if (delivered) {
      await DatabaseHelper.instance.markMessageDelivered(id);
      await _loadPeerMessageLogs();
    }
    // If it failed, the bubble's own "not delivered yet" marker (below)
    // carries that information now — it'll clear itself automatically via
    // _flushUndeliveredMessages() next time we reconnect.
  }

  String get _statusLabel {
    switch (_connState) {
      case ChatConnectionState.connecting:
        return "Connecting…";
      case ChatConnectionState.connected:
        return "Connected";
      case ChatConnectionState.disconnected:
        return "Disconnected";
      case ChatConnectionState.failed:
        return "Couldn't connect";
    }
  }

  Color _statusColor(ColorScheme colors) {
    switch (_connState) {
      case ChatConnectionState.connecting:
        return Colors.amber;
      case ChatConnectionState.connected:
        return Colors.green;
      case ChatConnectionState.disconnected:
      case ChatConnectionState.failed:
        return Colors.redAccent;
    }
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _msgInputController.dispose();
    _scrollController.dispose();
    // dispose() can't be awaited here (State.dispose() is synchronous) —
    // fire-and-forget teardown mirrors the rest of the app's BLE calls.
    _chatService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final canRetry = _connState == ChatConnectionState.failed ||
        _connState == ChatConnectionState.disconnected;

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ContactProfileScreen(
                peerUsername: widget.peerName,
                onDeleteContact: widget.onDeleteContact,
              ),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: colors.primary,
                backgroundImage: _peerAvatarPath != null ? FileImage(File(_peerAvatarPath!)) : null,
                child: _peerAvatarPath == null
                    ? const Icon(Icons.person, size: 18, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.peerName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: _statusColor(colors)),
                        const SizedBox(width: 4),
                        Text(
                          _statusLabel,
                          style: TextStyle(fontSize: 11, color: _statusColor(colors)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        elevation: 0,
        actions: [
          if (canRetry)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry connection',
              onPressed: _retryConnect,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messageThreadsList.isEmpty
                ? const Center(
                child: Text("No messages yet.",
                    style: TextStyle(color: Colors.grey)))
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: messageThreadsList.length,
              itemBuilder: (context, index) {
                final msg = messageThreadsList[index];
                bool isMe = msg[DatabaseHelper.columnSenderId] ==
                    myPersonalUsernameLabel;
                final delivered =
                    (msg[DatabaseHelper.columnDelivered] as int? ?? 1) == 1;
                final ts = msg[DatabaseHelper.columnTimestamp] as int;
                return Align(
                  alignment: isMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: isMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth:
                          MediaQuery.of(context).size.width * 0.75,
                        ),
                        decoration: BoxDecoration(
                          color: isMe
                              ? colors.primary
                              : colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          msg[DatabaseHelper.columnMessage],
                          style: TextStyle(
                              color: isMe ? Colors.white : Colors.black87),
                          maxLines: 10,
                          overflow: TextOverflow.ellipsis,
                          softWrap: true,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _fmtTime(ts),
                              style: TextStyle(
                                fontSize: 10,
                                color: colors.onSurface.withOpacity(0.4),
                              ),
                            ),
                            if (isMe && !delivered) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.schedule,
                                  size: 11, color: colors.onSurface.withOpacity(0.4)),
                              const SizedBox(width: 2),
                              Text(
                                "Not delivered yet",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurface.withOpacity(0.4),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.only(
                left: 16, right: 8, top: 10, bottom: 24),
            decoration: BoxDecoration(
                color: colors.surface.withOpacity(0.4)),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgInputController,
                    style: const TextStyle(fontSize: 14),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.6),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(100),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.arrow_upward,
                      color: Colors.white, size: 20),
                  style: IconButton.styleFrom(
                      backgroundColor: colors.primary,
                      padding: const EdgeInsets.all(12)),
                  onPressed: _send,
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
