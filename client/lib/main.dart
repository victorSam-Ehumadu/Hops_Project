import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'database_helper.dart'; // Make sure this path matches your folder structure!

void main() {
  // 1. Force Flutter to initialize before native platform logic runs
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Initialize Windows database bridge (Elijah's desk testing setup)
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // 3. Start the application
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HopsApp(),
  ));
}

class HopsApp extends StatefulWidget {
  const HopsApp({super.key});

  @override
  _HopsAppState createState() => _HopsAppState();
}

class _HopsAppState extends State<HopsApp> {
  String status = "Offline";
  List<Map<String, dynamic>> databaseMessages = []; // NEW: Directly hooked to Elijah's DB Schema
  final TextEditingController _msgController = TextEditingController();
  String? connectedId;
  final Uuid _uuid = const Uuid(); // For creating unique message IDs

  @override
  void initState() {
    super.initState();
    _loadMessagesFromDB(); // Fetch local messages history on app launch
  }

  // Reads from SQLite and triggers a UI update
  Future<void> _loadMessagesFromDB() async {
    final db = await DatabaseHelper.instance.database;
    final data = await db.query(DatabaseHelper.table, orderBy: '${DatabaseHelper.columnTimestamp} ASC');
    setState(() {
      databaseMessages = data;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Hops Mesh Messenger"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          children: [
            Text("Status: $status", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            const Divider(),

            // Synchronized Scrollable Chat History reading directly from Elijah's SQLite
            Expanded(
              child: databaseMessages.isEmpty
                  ? const Center(child: Text("No offline logs. Awaiting messages..."))
                  : ListView.builder(
                itemCount: databaseMessages.length,
                itemBuilder: (context, index) {
                  final msg = databaseMessages[index];
                  // 1 = True (Is for me), 0 = False (Relay message intended for someone else)
                  bool isForMe = msg[DatabaseHelper.columnIsForMe] == 1;
                  bool isMeSender = msg[DatabaseHelper.columnSenderId] == 'User_Vic';

                  return Align(
                    alignment: isMeSender ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 5),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isMeSender
                            ? Colors.orange[100]
                            : (isForMe ? Colors.blue[100] : Colors.grey[300]),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: isMeSender ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Text(msg[DatabaseHelper.columnMessage]),
                          const SizedBox(height: 3),
                          Text(
                            isMeSender
                                ? "Sent via Mesh"
                                : (isForMe ? "To You" : "Relaying Packet (Needs Forwarding: ${msg[DatabaseHelper.columnNeedsRelay] == 1})"),
                            style: TextStyle(fontSize: 10, color: Colors.black54),
                          )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(hintText: "Type a Hops message..."),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.orange),
                  onPressed: () async {
                    if (_msgController.text.isNotEmpty) {
                      String textToSend = _msgController.text;
                      String uniqueMsgId = _uuid.v4();

                      // Create the database payload record
                      final outgoingPayload = {
                        DatabaseHelper.columnId: uniqueMsgId,
                        DatabaseHelper.columnMessage: textToSend,
                        DatabaseHelper.columnSenderId: 'User_Vic',
                        DatabaseHelper.columnIsForMe: 0, // It's originating from you
                        DatabaseHelper.columnNeedsRelay: 1, // Nearby radios need to pick this up and relay it
                        DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
                      };

                      // 1. Commit instantly to Local SQLite Storage
                      await DatabaseHelper.instance.insertMessage(outgoingPayload);
                      _loadMessagesFromDB();

                      // 2. Transmit across active Bluetooth interface if a peer node is locked on
                      if (connectedId != null) {
                        Uint8List data = Uint8List.fromList(textToSend.codeUnits);
                        await Nearby().sendBytesPayload(connectedId!, data);
                      }

                      _msgController.clear();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(child: const Text("Listen"), onPressed: () => startDiscovery()),
                ElevatedButton(child: const Text("Beacon"), onPressed: () => startAdvertising()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void startAdvertising() async {
    await Nearby().stopAdvertising();
    setState(() => status = "Broadcasting...");
    try {
      await Nearby().startAdvertising("User_Vic", Strategy.P2P_CLUSTER,
          onConnectionInitiated: (id, info) => acceptConnection(id),
          onConnectionResult: (id, result) => print("Result: $result"),
          onDisconnected: (id) => setState(() => status = "Disconnected"),
          serviceId: "com.hops.app");
    } catch (e) { print(e); }
  }

  void startDiscovery() async {
    await Nearby().stopDiscovery();
    setState(() => status = "Searching...");
    try {
      await Nearby().startDiscovery("User_Vic", Strategy.P2P_CLUSTER,
          onEndpointFound: (id, name, serviceId) {
            Nearby().requestConnection("User_Vic", id,
              onConnectionInitiated: (id, info) => acceptConnection(id),
              onConnectionResult: (id, result) => print("Result: $result"),
              onDisconnected: (id) => setState(() => status = "Disconnected"),
            );
          },
          onEndpointLost: (id) {}, serviceId: "com.hops.app");
    } catch (e) { print(e); }
  }

  void acceptConnection(String id) {
    Nearby().acceptConnection(id, onPayLoadRecieved: (id, payload) async {
      if (payload.bytes != null) {
        String decodedString = String.fromCharCodes(payload.bytes!);

        // Formulate incoming network message block for local processing
        final incomingPayload = {
          DatabaseHelper.columnId: _uuid.v4(), // Wrap message with unique identifier
          DatabaseHelper.columnMessage: decodedString,
          DatabaseHelper.columnSenderId: id, // Track device ID that broadcasted it to you
          DatabaseHelper.columnIsForMe: 1, // Temporarily marked true for testing local direct chat
          DatabaseHelper.columnNeedsRelay: 0, // Flagged off unless packet dynamic routing rules trigger
          DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
        };

        // Inject packet natively into Elijah's DB engine
        await DatabaseHelper.instance.insertMessage(incomingPayload);

        // Instantly force UI to pull latest row entry logs
        _loadMessagesFromDB();
      }
    });
    setState(() { connectedId = id; status = "Connected!"; });
  }
}