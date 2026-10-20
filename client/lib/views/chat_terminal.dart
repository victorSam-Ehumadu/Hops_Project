// chat_terminal.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/services/bluetooth_permissions.dart';
import 'package:client/services/rfcomm_chat_service.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/views/contact_profile_screen.dart';
import 'package:client/main.dart'
    show
    nearbyConnectionsSessionCount,
    chatPingRequest,
    bleDirectMessageOutbox,
    bleDirectMessageInbox,
    BleDirectMessage;
import 'package:client/services/hops_constants.dart' show kDirectMessageMaxPlaintextBytes;
import 'package:client/services/hops_engine.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/services/accessibility_prefs.dart';
import 'package:client/theme/chat_bubble_skins.dart';
import 'package:client/utils/profanity_filter.dart';
import 'package:client/widgets/hops_bot_avatar.dart';

class IndividualChatTerminalView extends StatefulWidget {
  final String peerName;
  final Future<void> Function(String peerUsername) onDeleteContact;
  final bool isBot;

  const IndividualChatTerminalView({
    super.key,
    required this.peerName,
    required this.onDeleteContact,
    this.isBot = false,
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

  RfcommChatService? _chatService;
  ChatConnectionState _connState = ChatConnectionState.connecting;
  bool _missingPermissions = false;
  String? _peerAvatarPath;

  bool _pingInFlight = false;
  DateTime? _lastPingAt;
  static const Duration _kChatPingCooldown = Duration(minutes: 2);

  // ── BLE mesh fallback ──────────────────────────────────────────────────
  bool _bleFallbackActive = false;
  Timer? _bleFallbackTimer;
  StreamSubscription<BleDirectMessage>? _bleInboxSub;
  // Deliberately SHORTER than a full RFCOMM cycle, which is up to ~56s in
  // the worst case (see rfcomm_chat_service.dart's _connectAttemptInterval).
  // Offering the mesh early is the right trade because the fallback is
  // purely additive: RFCOMM keeps retrying underneath it, and the moment it
  // connects this clears itself and the status flips back to "Connected"
  // (see onStateChanged). So the cost of being early is that one message
  // may go the slower way; the cost of being late is a user who cannot send
  // anything at all while a handshake grinds on. The second is worse.
  static const Duration _bleFallbackAfter = Duration(seconds: 45);

  bool _botThinking = false;

  @override
  void initState() {
    super.initState();
    CosmeticPrefs.instance.load();

    if (widget.isBot) {
      UnreadTracker.instance.clear(UnreadSource.directMessage);
      _connState = ChatConnectionState.connected;
      _initBotThread();
      return;
    }

    nearbyConnectionsSessionCount.value++;
    UnreadTracker.instance.clear(UnreadSource.directMessage);
    _init();

    _refreshTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _loadPeerMessageLogs());

    _bleInboxSub = bleDirectMessageInbox.stream.listen((msg) {
      if (msg.peerUsername != widget.peerName) return;
      _handleIncomingMessage(msg.text);
    });

    _armBleFallbackTimer();
  }

  void _armBleFallbackTimer() {
    _bleFallbackTimer?.cancel();
    _bleFallbackTimer = Timer(_bleFallbackAfter, () {
      if (!mounted || _connState == ChatConnectionState.connected) return;
      setState(() => _bleFallbackActive = true);
    });
  }

  // ── Assistant thread ───────────────────────────────────────────────────

  Future<void> _initBotThread() async {
    final prefs = await SharedPreferences.getInstance();
    myPersonalUsernameLabel = prefs.getString('my_username') ?? 'User_Vic';
    await _loadPeerMessageLogs();

    if (messageThreadsList.isEmpty) {
      await _writeBotMessage(HopsEngine.instance.greeting);
    }

    unawaited(HopsEngine.instance.init());
  }

  Future<void> _writeBotMessage(String text) async {
    await DatabaseHelper.instance.insertMessage({
      DatabaseHelper.columnId: const Uuid().v4(),
      DatabaseHelper.columnMessage: text,
      DatabaseHelper.columnSenderId: widget.peerName,
      DatabaseHelper.columnPeerId: widget.peerName,
      DatabaseHelper.columnIsForMe: 1,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnDelivered: 1,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    });
    await _loadPeerMessageLogs();
  }

  Future<void> _clearBotThread() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Clear this chat?"),
        content: Text(
            "Deletes your conversation with ${widget.peerName} from this device. "
                "Hops stays in your contacts."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("Clear"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await DatabaseHelper.instance.deleteConversationWithPeer(widget.peerName);
    await _loadPeerMessageLogs();
    await _writeBotMessage(HopsEngine.instance.greeting);
  }

  Future<void> _sendToBot(String text) async {
    await DatabaseHelper.instance.insertMessage({
      DatabaseHelper.columnId: const Uuid().v4(),
      DatabaseHelper.columnMessage: text,
      DatabaseHelper.columnSenderId: myPersonalUsernameLabel,
      DatabaseHelper.columnPeerId: widget.peerName,
      DatabaseHelper.columnIsForMe: 0,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnDelivered: 1,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    });
    await _loadPeerMessageLogs();

    if (mounted) setState(() => _botThinking = true);
    final reply = await HopsEngine.instance.askBunny(text);
    await Future.delayed(const Duration(milliseconds: 450));
    if (mounted) setState(() => _botThinking = false);
    await _writeBotMessage(reply);
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    myPersonalUsernameLabel = prefs.getString('my_username') ?? 'User_Vic';

    final cachedProfile =
    await DatabaseHelper.instance.getContactProfile(widget.peerName);
    _peerAvatarPath = cachedProfile?[DatabaseHelper.cpColAvatarPath] as String?;
    final knownMac = cachedProfile?[DatabaseHelper.cpColRfcommMac] as String?;
    if (mounted) setState(() {});

    await _loadPeerMessageLogs();

    _chatService = RfcommChatService(
      myUsername: myPersonalUsernameLabel,
      peerUsername: widget.peerName,
      knownMacAddress: knownMac,
      onMacLearned: (mac) =>
          DatabaseHelper.instance.upsertContactMacAddress(widget.peerName, mac),
      onMessageReceived: (id, text) => _handleIncomingMessage(text, id: id),
      onMessageDeleted: _handleIncomingDelete,
      onProfileReceived: _handlePeerProfileReceived,
      onRotatingSeedReceived: _handlePeerSeedReceived,
      onStateChanged: (state) {
        if (!mounted) return;
        setState(() {
          _connState = state;
          if (state == ChatConnectionState.failed) _bleFallbackActive = true;
          if (state == ChatConnectionState.connected) {
            _bleFallbackActive = false;
            _bleFallbackTimer?.cancel();
          }
        });
        if (state == ChatConnectionState.connected) {
          _flushUndeliveredMessages();
          _sendMyProfile();
          _sendMyRotatingSeed();
        }
      },
    );
    await _connectWithPermissions();
  }

  Future<void> _connectWithPermissions() async {
    final granted = await BluetoothPermissions.request();

    if (!mounted) return;
    if (!granted) {
      setState(() {
        _missingPermissions = true;
        _connState = ChatConnectionState.failed;
      });
      return;
    }

    setState(() => _missingPermissions = false);
    await _chatService!.connect();
  }

  Future<void> _sendMyRotatingSeed() async {
    const storage = FlutterSecureStorage();
    final seedB64 = await storage.read(key: 'rotating_id_seed');
    if (seedB64 == null) return;
    try {
      await _chatService?.sendRotatingSeed(base64Decode(seedB64));
    } catch (_) {}
  }

  Future<void> _handlePeerSeedReceived(Uint8List seed) async {
    await DatabaseHelper.instance
        .upsertContactRotatingSeed(widget.peerName, base64Encode(seed));
  }

  Future<void> _sendMyProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final bio = prefs.getString('bio') ?? '';
    final thinking = prefs.getString('thinking_status') ?? '';
    final avatarPath = prefs.getString('avatar_path');
    Uint8List? avatarBytes;
    if (avatarPath != null) {
      try {
        final file = File(avatarPath);
        if (await file.exists()) avatarBytes = await file.readAsBytes();
      } catch (_) {}
    }
    await _chatService?.sendProfile(
        bio: bio, thinking: thinking, avatarBytes: avatarBytes);
  }

  Future<void> _handlePeerProfileReceived(
      String bio, String thinking, Uint8List? avatarBytes) async {
    String? savedAvatarPath;
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      try {
        final previousPath = _peerAvatarPath;
        final dir = await getApplicationDocumentsDirectory();
        final file = File(
            '${dir.path}/contact_avatar_${widget.peerName}_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await file.writeAsBytes(avatarBytes, flush: true);
        savedAvatarPath = file.path;

        if (previousPath != null && previousPath != savedAvatarPath) {
          final oldFile = File(previousPath);
          if (await oldFile.exists()) {
            try {
              await oldFile.delete();
            } catch (_) {}
          }
        }
      } catch (_) {
        savedAvatarPath = _peerAvatarPath;
      }
    }
    await DatabaseHelper.instance.upsertContactProfile(
      widget.peerName,
      avatarPath: savedAvatarPath,
      bio: bio,
      thinking: thinking,
    );
    if (mounted) setState(() => _peerAvatarPath = savedAvatarPath);
  }

  Future<void> _pingPeerToWakeUp() async {
    if (_pingInFlight) return;
    if (_connState == ChatConnectionState.connected) return;

    final last = _lastPingAt;
    if (last != null &&
        DateTime.now().difference(last) < _kChatPingCooldown) {
      return;
    }
    _lastPingAt = DateTime.now();

    _pingInFlight = true;
    try {
      await _chatService?.pauseForPing();
      chatPingRequest.value = widget.peerName;
      await Future.delayed(const Duration(seconds: 3));
      await _chatService?.resumeAfterPing();
    } finally {
      _pingInFlight = false;
    }
  }

  Future<void> _retryConnect() async {
    if (_missingPermissions) {
      await _connectWithPermissions();
      return;
    }
    setState(() {
      _connState = ChatConnectionState.connecting;
      _bleFallbackActive = false;
    });
    _armBleFallbackTimer();
    await _chatService?.connect();
  }

  Future<void> _flushUndeliveredMessages() async {
    final pending = await DatabaseHelper.instance
        .getUndeliveredMessagesForPeer(widget.peerName, myPersonalUsernameLabel);
    if (pending.isEmpty) return;

    for (final row in pending) {
      final id = row[DatabaseHelper.columnId] as String;
      final text = row[DatabaseHelper.columnMessage] as String;
      final delivered = await _chatService?.sendMessage(id, text) ?? false;
      if (!delivered) break;
      await DatabaseHelper.instance.markMessageDelivered(id);
    }
    await _loadPeerMessageLogs();
  }

  Future<void> _handleIncomingMessage(String message, {String? id}) async {
    final incomingPayload = {
      DatabaseHelper.columnId: id ?? const Uuid().v4(),
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

    if (AccessibilityPrefs.instance.readMessagesAloud.value) {
      unawaited(HopsEngine.instance.bunnyTalk(message));
    }

    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      UnreadTracker.instance.mark(UnreadSource.directMessage);
      await NotificationService.showChatMessageNotification(
        peerUsername: widget.peerName,
        message: message,
      );
    }
  }

  Future<void> _loadPeerMessageLogs() async {
    final data =
    await DatabaseHelper.instance.getMessagesForPeer(widget.peerName);
    if (!mounted) return;
    setState(() => messageThreadsList = data);
    _scrollToBottom();
  }

  Future<void> _confirmDeleteMessage(String id) async {
    final colors = Theme.of(context).colorScheme;
    final canReachPeer = _connState == ChatConnectionState.connected;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: Text(
          canReachPeer
              ? "This removes it from your conversation. Since you're "
              "currently connected to ${widget.peerName}, it will be "
              "removed from their device too."
              : "This removes it from your own copy of the conversation. "
              "You're not connected to ${widget.peerName} right now, so "
              "it can't be removed from their device.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DatabaseHelper.instance.deleteMessage(id);
    await _loadPeerMessageLogs();
    unawaited(_chatService?.sendDeleteMessage(id));
  }

  Future<void> _handleIncomingDelete(String id) async {
    await DatabaseHelper.instance.deleteMessage(id);
    await _loadPeerMessageLogs();
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
    var text = _msgInputController.text.trim();
    if (text.isEmpty) return;
    _msgInputController.clear();

    if (widget.isBot) {
      await _sendToBot(text);
      return;
    }
    text = censorProfanity(text);

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

    final delivered = await _chatService?.sendMessage(id, text) ?? false;
    if (delivered) {
      await DatabaseHelper.instance.markMessageDelivered(id);
      await _loadPeerMessageLogs();
      return;
    }

    if (_bleFallbackActive && await _sendViaBleFallback(text)) {
      await DatabaseHelper.instance.markMessageDelivered(id);
      await _loadPeerMessageLogs();
      return;
    }

    unawaited(_pingPeerToWakeUp());
  }

  Future<bool> _sendViaBleFallback(String text) async {
    if (utf8.encode(text).length > kDirectMessageMaxPlaintextBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              "Too long for Bluetooth mesh — keep it under $kDirectMessageMaxPlaintextBytes characters while the direct connection is unavailable."),
        ));
      }
      return false;
    }
    final completer = Completer<bool>();
    bleDirectMessageOutbox.value = BleDirectMessage(
      peerUsername: widget.peerName,
      text: text,
      sent: completer,
    );
    final sent = await completer.future
        .timeout(const Duration(seconds: 5), onTimeout: () => false);
    // HopsApp renames the Bluetooth adapter to broadcast the mesh chunks and
    // restores the device's default name afterwards. Re-assert our Hops
    // username so RFCOMM discovery can still find us if it's still retrying.
    unawaited(_chatService?.restoreRfcommAdapterName());
    return sent;
  }

  String get _statusLabel {
    if (widget.isBot) return "Always available · works offline";
    if (_missingPermissions) return "Bluetooth & location permission needed";
    if (_connState == ChatConnectionState.connected) return "Connected";
    if (_bleFallbackActive) return "Via Bluetooth mesh · slower, no delivery receipt";
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
    if (widget.isBot) return Colors.green;
    if (_connState == ChatConnectionState.connected) return Colors.green;
    if (_bleFallbackActive) return Colors.amber;
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
    if (widget.isBot) {
      HopsEngine.instance.stopTalking();
      _msgInputController.dispose();
      _scrollController.dispose();
      super.dispose();
      return;
    }
    nearbyConnectionsSessionCount.value--;
    _refreshTimer?.cancel();
    _bleFallbackTimer?.cancel();
    _bleInboxSub?.cancel();
    _msgInputController.dispose();
    _scrollController.dispose();
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
          onTap: widget.isBot
              ? null
              : () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ContactProfileScreen(
                peerUsername: widget.peerName,
                onDeleteContact: widget.onDeleteContact,
              ),
            ),
          ),
          child: Row(
            children: [
              if (widget.isBot)
                const HopsBotAvatar(radius: 16, showStatusDot: false)
              else
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colors.primary,
                  backgroundImage: _peerAvatarPath != null
                      ? FileImage(File(_peerAvatarPath!))
                      : null,
                  child: _peerAvatarPath == null
                      ? const Icon(Icons.cruelty_free,
                      size: 18, color: Colors.white)
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
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle,
                            size: 8, color: _statusColor(colors)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _statusLabel,
                            style: TextStyle(
                                fontSize: 11, color: _statusColor(colors)),
                            overflow: TextOverflow.ellipsis,
                          ),
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
          if (widget.isBot)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear chat',
              onPressed: _clearBotThread,
            ),
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
                ? Center(
                child: Text("No messages yet.",
                    style: TextStyle(
                        color: colors.onSurface.withValues(alpha: 0.5))))
                : ValueListenableBuilder<String>(
              valueListenable: CosmeticPrefs.instance.bubbleSkin,
              builder: (context, bubbleSkinId, _) {
                final skin = BubbleSkinOptions.byId(bubbleSkinId);
                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messageThreadsList.length,
                  itemBuilder: (context, index) {
                    final msg = messageThreadsList[index];
                    bool isMe = msg[DatabaseHelper.columnSenderId] ==
                        myPersonalUsernameLabel;
                    final delivered =
                        (msg[DatabaseHelper.columnDelivered] as int? ??
                            1) ==
                            1;
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
                          GestureDetector(
                            onTap: (widget.isBot && !isMe)
                                ? () => HopsEngine.instance.bunnyTalk(
                                msg[DatabaseHelper.columnMessage]
                                as String)
                                : null,
                            onLongPress: (isMe && !widget.isBot)
                                ? () => _confirmDeleteMessage(
                                msg[DatabaseHelper.columnId]
                                as String)
                                : null,
                            child: Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              constraints: BoxConstraints(
                                maxWidth:
                                MediaQuery.of(context).size.width *
                                    0.75,
                              ),
                              decoration: BoxDecoration(
                                color: isMe
                                    ? (skin.bubbleColor ?? colors.primary)
                                    : colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                msg[DatabaseHelper.columnMessage],
                                style: TextStyle(
                                    color: isMe
                                        ? (skin.textColor ?? Colors.white)
                                        : colors.onSurface),
                                maxLines: widget.isBot ? null : 10,
                                overflow: widget.isBot
                                    ? TextOverflow.clip
                                    : TextOverflow.ellipsis,
                                softWrap: true,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(
                                top: 2, left: 4, right: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _fmtTime(ts),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                                if (isMe && !delivered) ...[
                                  const SizedBox(width: 4),
                                  Icon(Icons.schedule,
                                      size: 11,
                                      color: colors.onSurface
                                          .withValues(alpha: 0.4)),
                                  const SizedBox(width: 2),
                                  Text(
                                    "Not delivered yet",
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: colors.onSurface
                                          .withValues(alpha: 0.4),
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
                );
              },
            ),
          ),
          if (_botThinking)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, bottom: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary.withValues(alpha: 0.5)),
                    ),
                    const SizedBox(width: 8),
                    Text("Hops is thinking…",
                        style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: colors.onSurface.withValues(alpha: 0.5))),
                  ],
                ),
              ),
            ),
          Container(
            padding:
            const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 24),
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
                    controller: _msgInputController,
                    style: const TextStyle(fontSize: 14),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      filled: true,
                      fillColor: colors.surfaceContainerHighest,
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