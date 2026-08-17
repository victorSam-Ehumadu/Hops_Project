// chat_terminal.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
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
import 'package:client/widgets/hops_bot_avatar.dart';

class IndividualChatTerminalView extends StatefulWidget {
  final String peerName;
  // Threaded down to ContactProfileScreen when the app-bar avatar is
  // tapped — the actual contacts state (_addedFriends etc.) lives in
  // HopsApp, not here, so deletion has to be delegated back up to it.
  final Future<void> Function(String peerUsername) onDeleteContact;

  /// Talking to the built-in assistant rather than another phone. Every
  /// transport in this file is bypassed: there's no peer, no radio, no
  /// delivery state — replies come from HopsEngine on this device. Kept as
  /// a flag on the existing screen rather than a separate widget so the bot
  /// thread looks and scrolls exactly like a real one, and so its history
  /// lives in the same `messages` table as everything else.
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
  // True once we've confirmed the Bluetooth/location runtime permissions
  // RFCOMM discovery/connection needs are missing — without these,
  // classic-Bluetooth discovery silently finds nothing and the chat never
  // connects.
  bool _missingPermissions = false;

  // The peer's avatar/bio, learned only by direct exchange over this same
  // connection — see HopsChatService.sendProfile. _peerAvatarPath reflects
  // whatever's cached from a previous chat until (if) a fresh one arrives.
  String? _peerAvatarPath;

  // Guards _pingPeerToWakeUp so two overlapping pings (e.g. sending a
  // couple of messages in a row while still not connected) don't step on
  // each other's pause/resume of the Nearby Connections session.
  bool _pingInFlight = false;

  // ── BLE mesh fallback ──────────────────────────────────────────────────
  // RFCOMM (rfcomm_chat_service.dart) is the primary transport: a real
  // socket, full-length messages, instant delivery. But it depends on
  // classic-Bluetooth discovery and, for a never-before-paired contact, a
  // system discoverability prompt — plenty of ways for it to legitimately
  // fail. When it does, rather than leaving the chat dead, messages fall
  // back to the same chunked-advertisement-name channel Community Alerts and
  // Emergency Flare use (encrypted — see mesh_crypto.dart's
  // sealDirectMessage and its documented limits, since advertisements are
  // a public broadcast). Much slower and length-capped, but it works
  // wherever the rest of the mesh works.
  bool _bleFallbackActive = false;
  Timer? _bleFallbackTimer;
  StreamSubscription<BleDirectMessage>? _bleInboxSub;
  static const Duration _bleFallbackAfter = Duration(seconds: 35);

  // Bot only: true while a reply is being composed, so the thread shows a
  // "typing" line instead of the answer appearing the instant you hit send.
  bool _botThinking = false;

  @override
  void initState() {
    super.initState();

    // The assistant needs none of the machinery below — no radio to pause,
    // no peer to discover, no fallback transport to arm. Starting any of it
    // would fight the mesh HopsApp is running underneath for no reason.
    if (widget.isBot) {
      UnreadTracker.instance.clear(UnreadSource.directMessage);
      _connState = ChatConnectionState.connected;
      _initBotThread();
      return;
    }

    // Tells HopsApp (still alive underneath this pushed screen) to pause
    // its own background BLE advertising-refresh/scan-cycle timers for as
    // long as this chat is open — those otherwise keep firing regardless
    // of what's on top of HopsApp and fight RFCOMM's own classic-Bluetooth
    // discovery/connection attempt for the same radio. Named for the
    // transport this originally guarded (nearby_connections) but the
    // reasoning — and the need to pause — is identical for RFCOMM. See
    // hops_app.dart's _pauseBackgroundBleForNearbyConnections.
    nearbyConnectionsSessionCount.value++;
    // Reading this conversation clears the Contacts-tab dot.
    UnreadTracker.instance.clear(UnreadSource.directMessage);
    _init();

    // Light periodic fallback — the real-time path is _chatService's
    // onMessageReceived callback below, but this also picks up rows
    // written by the older pairing-code contact log while the screen
    // is open.
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _loadPeerMessageLogs());

    // Incoming BLE-mesh messages (see _bleFallbackActive's comment).
    // Subscribed unconditionally rather than only once fallback is active:
    // the peer may drop to fallback before we do, and a message that
    // arrives that way should show up regardless of which transport this
    // side currently thinks it's using.
    _bleInboxSub = bleDirectMessageInbox.stream.listen((msg) {
      if (msg.peerUsername != widget.peerName) return;
      _handleIncomingMessage(msg.text);
    });

    // Give RFCOMM a fair window to connect before falling back.
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

    // First ever visit — leave an opening line so the thread isn't an empty
    // room. Written to the same table as everything else, so it survives
    // and this only fires once.
    if (messageThreadsList.isEmpty) {
      await _writeBotMessage(HopsEngine.instance.greeting);
    }

    // Warm the engine (asset read + TTS voice lookup) while the user is
    // still reading, so the first question doesn't wait on it.
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

  /// Wipes the assistant thread and starts it over from the greeting.
  ///
  /// The bot's own entry point for this: every other contact reaches
  /// "delete" through ContactProfileScreen, which is disabled for the bot
  /// (no bio, no avatar exchange, and its delete would offer to remove
  /// something that can't be removed) — leaving the bot with no way to
  /// clear its history at all. HopsApp._deleteContact already special-cases
  /// the bot to mean "clear the chat" rather than "remove the contact";
  /// this is the button that actually gets there.
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
    // Straight back to a fresh thread rather than an empty one — an
    // assistant that greets you is the whole point of the first message.
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
      // Nothing to deliver it to but this device — never show the
      // "Not delivered yet" marker on a message that has already arrived.
      DatabaseHelper.columnDelivered: 1,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    });
    await _loadPeerMessageLogs();

    if (mounted) setState(() => _botThinking = true);
    final reply = await HopsEngine.instance.askBunny(text);
    // A lookup returns in microseconds; replying that fast reads as a form
    // letter rather than an answer. The pause is the whole reason for the
    // typing indicator.
    await Future.delayed(const Duration(milliseconds: 450));
    if (mounted) setState(() => _botThinking = false);
    // Written even if the screen was closed mid-think, so the answer is
    // waiting in the thread next time rather than lost.
    await _writeBotMessage(reply);
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    myPersonalUsernameLabel = prefs.getString('my_username') ?? 'User_Vic';

    // Show whatever avatar we already cached from a previous chat with
    // this peer, if any, before a fresh exchange (re)confirms it. Also
    // doubles as the source for a previously-learned MAC address (see
    // RfcommChatService.knownMacAddress) — one row, one query, both uses.
    final cachedProfile = await DatabaseHelper.instance.getContactProfile(widget.peerName);
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
      onMessageReceived: _handleIncomingMessage,
      onProfileReceived: _handlePeerProfileReceived,
      onRotatingSeedReceived: _handlePeerSeedReceived,
      onStateChanged: (state) {
        if (!mounted) return;
        setState(() {
          _connState = state;
          // RFCOMM gave up entirely — no reason to keep waiting out the
          // timer above before offering the fallback.
          if (state == ChatConnectionState.failed) _bleFallbackActive = true;
          // A real socket beats the mesh on every axis; if RFCOMM connects
          // (even late, via its own retry watchdog), stop using fallback.
          if (state == ChatConnectionState.connected) _bleFallbackActive = false;
        });
        if (state == ChatConnectionState.connected) {
          // Anything sent while the peer wasn't reachable is still sitting
          // undelivered — now that we're connected, try again instead of
          // leaving it stranded until the user notices and re-sends by hand.
          _flushUndeliveredMessages();
          _sendMyProfile();
          _sendMyRotatingSeed();
        }
      },
    );
    await _connectWithPermissions();
  }

  // RFCOMM's classic-Bluetooth discovery/connect needs this set. Skipping
  // it doesn't throw — discovery just silently finds nothing, which used
  // to make every 1:1 chat hang on "Connecting…" forever with no
  // explanation (same failure mode nearby_connections had for the same
  // reason, before this transport swap — see rfcomm_chat_service.dart).
  // No Wi-Fi-adjacent permission needed at all now, unlike before.
  Future<void> _connectWithPermissions() async {
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ].request();

    final granted = statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );

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
    if (seedB64 == null) return; // pre-rotating-ID account — nothing to send yet
    try {
      await _chatService?.sendRotatingSeed(base64Decode(seedB64));
    } catch (_) {
      // Best-effort — chat itself still works without this.
    }
  }

  Future<void> _handlePeerSeedReceived(Uint8List seed) async {
    await DatabaseHelper.instance
        .upsertContactRotatingSeed(widget.peerName, base64Encode(seed));
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

  // Lets the peer know a message is waiting for them even though RFCOMM
  // discovery/connection alone can't reach them — they're not necessarily
  // running a matching session at all (e.g. they haven't opened this same
  // chat screen). Briefly steps the RFCOMM attempt aside so a short
  // BLE-peripheral CHT: ping (broadcast by HopsApp, see chatPingRequest in
  // main.dart) can use the radio instead, then hands it back. Any Hops
  // device with the app running — foreground or backgrounded — picks the
  // ping up via its always-on scan and shows a system notification,
  // regardless of what screen they're on.
  Future<void> _pingPeerToWakeUp() async {
    if (_pingInFlight) return;
    if (_connState == ChatConnectionState.connected) return; // already reachable — nothing to ping for
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
      // Permissions may have been granted from the app-settings screen
      // since the last attempt (openAppSettings() below sends the user
      // there) — re-check rather than retrying a connect that's doomed
      // to hang again.
      await _connectWithPermissions();
      return;
    }
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

    // Only while this exact conversation isn't the thing on screen right
    // now — otherwise every incoming message would double up as both the
    // live chat bubble appearing AND a redundant notification banner for
    // the exact same message you're already looking at.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      UnreadTracker.instance.mark(UnreadSource.directMessage);
      await NotificationService.showChatMessageNotification(
        peerUsername: widget.peerName,
        message: message,
      );
    }
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

    if (widget.isBot) {
      await _sendToBot(text);
      return;
    }

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
      return;
    }

    // RFCOMM couldn't take it. Try the BLE mesh before giving up.
    if (_bleFallbackActive && await _sendViaBleFallback(text)) {
      // "Delivered" here means "successfully broadcast", not "confirmed
      // received" — the mesh channel is fire-and-forget with no ack of any
      // kind (same as Emergency Flare). The status line makes that
      // distinction visible rather than leaving it implied by the tick.
      await DatabaseHelper.instance.markMessageDelivered(id);
      await _loadPeerMessageLogs();
      return;
    }

    // Neither transport could take it — the bubble's own "not delivered
    // yet" marker (below) carries that locally, and
    // _flushUndeliveredMessages() will retry once we do connect, but
    // neither of those helps if the peer isn't running a matching session
    // at all right now. Ping them so their phone can tell them a message
    // is waiting, wherever they are in the app (or if it's backgrounded).
    unawaited(_pingPeerToWakeUp());
  }

  // Hands the message to HopsApp's BLE peripheral (see main.dart's
  // bleDirectMessageOutbox and hops_app.dart's _broadcastDirectMessage).
  // Returns false if it couldn't be broadcast at all — most commonly
  // because no rotating-ID seed has ever been exchanged with this contact,
  // so there's no shared key to encrypt with.
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
    // Bounded wait — if HopsApp isn't mounted (shouldn't happen; this
    // screen is pushed on top of it) nothing would ever complete this.
    return completer.future
        .timeout(const Duration(seconds: 5), onTimeout: () => false);
  }

  String get _statusLabel {
    // Not a claim about the radio — the assistant runs on this device, so
    // it's reachable whether or not anything else is.
    if (widget.isBot) return "Always available · works offline";
    if (_missingPermissions) return "Bluetooth & location permission needed";
    if (_connState == ChatConnectionState.connected) return "Connected";
    // Fallback wins the label over "Couldn't connect"/"Connecting…" —
    // messages genuinely can be sent in this state, so reporting it as a
    // failure would be wrong, but it's also not the fast direct link, so
    // it shouldn't just say "Connected" either.
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
      // Nothing was started for the bot thread except the controllers —
      // decrementing the session counter here would drop HopsApp's BLE
      // pause count below zero and resume scanning for a real chat that's
      // still open underneath.
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
          // No profile card for the assistant — there's no peer behind it to
          // show a bio for, and that screen's delete action would offer to
          // remove a contact that's meant to always be there.
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
                // Status dot omitted at this size — it'd read as a speck
                // rather than a signal, and the status line right beside it
                // already says "Always available".
                const HopsBotAvatar(radius: 16, showStatusDot: false)
              else
                CircleAvatar(
                  radius: 16,
                  backgroundColor: colors.primary,
                  backgroundImage:
                      _peerAvatarPath != null ? FileImage(File(_peerAvatarPath!)) : null,
                  child: _peerAvatarPath == null
                      ? const Icon(Icons.cruelty_free, size: 18, color: Colors.white)
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
                    style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5))))
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
                      GestureDetector(
                        // Tap one of Hops' replies to hear it read aloud —
                        // the point of the assistant's voice is hands-free
                        // first aid, where reading a screen is the thing you
                        // can't do. Only its own messages, and only in the
                        // bot thread.
                        onTap: (widget.isBot && !isMe)
                            ? () => HopsEngine.instance.bunnyTalk(
                                msg[DatabaseHelper.columnMessage] as String)
                            : null,
                        child: Container(
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
                          // Bot answers run longer than mesh messages, which
                          // are capped by the advertisement budget. Ten lines
                          // with an ellipsis would cut first-aid steps off
                          // mid-instruction.
                          style: TextStyle(
                              color: isMe ? Colors.white : colors.onSurface),
                          maxLines: widget.isBot ? null : 10,
                          overflow: widget.isBot
                              ? TextOverflow.clip
                              : TextOverflow.ellipsis,
                          softWrap: true,
                        ),
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
                                color: colors.onSurface.withValues(alpha: 0.4),
                              ),
                            ),
                            if (isMe && !delivered) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.schedule,
                                  size: 11, color: colors.onSurface.withValues(alpha: 0.4)),
                              const SizedBox(width: 2),
                              Text(
                                "Not delivered yet",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colors.onSurface.withValues(alpha: 0.4),
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
                          strokeWidth: 2, color: colors.primary.withValues(alpha: 0.5)),
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
            padding: const EdgeInsets.only(
                left: 16, right: 8, top: 10, bottom: 24),
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
