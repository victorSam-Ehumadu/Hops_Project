import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/services/chat_connection_service.dart';

class IndividualChatTerminalView extends StatefulWidget {
  final String peerName;
  final ChatConnectionService? chatService;   // nullable

  const IndividualChatTerminalView({
    super.key,
    required this.peerName,
    this.chatService,
  });

  @override
  State<IndividualChatTerminalView> createState() =>
      _IndividualChatTerminalViewState();
}

class _IndividualChatTerminalViewState
    extends State<IndividualChatTerminalView> {
  List<Map<String, dynamic>> messageThreadsList = [];
  final TextEditingController _msgInputController = TextEditingController();
  String myPersonalUsernameLabel = "User_Vic";
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadDeviceOwnerLabel();
    _loadPeerMessageLogs();

    // Set up listener for incoming messages if we have a live connection
    if (widget.chatService != null) {
      widget.chatService!.onMessageReceived = (sender, message) async {
        final incomingPayload = {
          DatabaseHelper.columnId: const Uuid().v4(),
          DatabaseHelper.columnMessage: message,
          DatabaseHelper.columnSenderId: sender,
          DatabaseHelper.columnIsForMe: 1,
          DatabaseHelper.columnNeedsRelay: 0,
          DatabaseHelper.columnTimestamp:
          DateTime.now().millisecondsSinceEpoch,
        };
        await DatabaseHelper.instance.insertMessage(incomingPayload);
        _loadPeerMessageLogs();
      };
    }

    _refreshTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _loadPeerMessageLogs());
  }

  Future<void> _loadDeviceOwnerLabel() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      myPersonalUsernameLabel = prefs.getString('my_username') ?? 'User_Vic';
    });
  }

  Future<void> _loadPeerMessageLogs() async {
    final db = await DatabaseHelper.instance.database;
    final data = await db.query(
      DatabaseHelper.table,
      where:
      '${DatabaseHelper.columnSenderId} = ? OR ${DatabaseHelper.columnSenderId} = ?',
      whereArgs: [widget.peerName, myPersonalUsernameLabel],
      orderBy: '${DatabaseHelper.columnTimestamp} ASC',
    );
    setState(() {
      messageThreadsList = data;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _msgInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isConnected = widget.chatService?.isConnected ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(
                widget.peerName,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 18),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isConnected)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.circle, size: 10, color: Colors.green),
              ),
          ],
        ),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: messageThreadsList.isEmpty
                ? const Center(
                child: Text("No messages yet.",
                    style: TextStyle(color: Colors.grey)))
                : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: messageThreadsList.length,
              itemBuilder: (context, index) {
                final msg = messageThreadsList[index];
                bool isMe = msg[DatabaseHelper.columnSenderId] ==
                    myPersonalUsernameLabel;
                return Align(
                  alignment: isMe
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
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
                  onPressed: () async {
                    if (_msgInputController.text.isNotEmpty) {
                      final text = _msgInputController.text.trim();
                      final outgoingPayload = {
                        DatabaseHelper.columnId: const Uuid().v4(),
                        DatabaseHelper.columnMessage: text,
                        DatabaseHelper.columnSenderId:
                        myPersonalUsernameLabel,
                        DatabaseHelper.columnIsForMe: 0,
                        DatabaseHelper.columnNeedsRelay: 1,
                        DatabaseHelper.columnTimestamp:
                        DateTime.now().millisecondsSinceEpoch,
                      };
                      await DatabaseHelper.instance
                          .insertMessage(outgoingPayload);
                      _loadPeerMessageLogs();
                      // Send over Nearby if connected
                      widget.chatService?.sendMessage(text);
                      _msgInputController.clear();
                    }
                  },
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}