import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';

void main() => runApp(MaterialApp(home: HopsApp()));

class HopsApp extends StatefulWidget {
  @override
  _HopsAppState createState() => _HopsAppState();
}

class _HopsAppState extends State<HopsApp> {
  String status = "Offline";
  List<String> chatHistory = []; // NEW: This stores the whole conversation
  final TextEditingController _msgController = TextEditingController();
  String? connectedId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Hops Mesh Messenger"), backgroundColor: Colors.orange),
      body: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          children: [
            Text("Status: $status", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            Divider(),

            // NEW: The Scrollable Chat History Area
            Expanded(
              child: ListView.builder(
                itemCount: chatHistory.length,
                itemBuilder: (context, index) {
                  bool isMe = chatHistory[index].startsWith("You:");
                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: EdgeInsets.symmetric(vertical: 5),
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isMe ? Colors.orange[100] : Colors.blue[100],
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(chatHistory[index]),
                    ),
                  );
                },
              ),
            ),

            Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: InputDecoration(hintText: "Type a Hops message..."),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.send, color: Colors.orange),
                  onPressed: () async {
                    if (connectedId != null && _msgController.text.isNotEmpty) {
                      Uint8List data = Uint8List.fromList(_msgController.text.codeUnits);
                      await Nearby().sendBytesPayload(connectedId!, data);
                      setState(() {
                        chatHistory.add("You: ${_msgController.text}"); // Add to list
                      });
                      _msgController.clear();
                    }
                  },
                ),
              ],
            ),
            SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(child: Text("Listen"), onPressed: () => startDiscovery()),
                ElevatedButton(child: Text("Beacon"), onPressed: () => startAdvertising()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void startAdvertising() async {
    await Nearby().stopAdvertising(); // NEW: Kill any old beacon first
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
    await Nearby().stopDiscovery(); // NEW: Kill any old search first
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
    Nearby().acceptConnection(id, onPayLoadRecieved: (id, payload) {
      if (payload.bytes != null) {
        setState(() {
          chatHistory.add("Them: ${String.fromCharCodes(payload.bytes!)}"); // Add received msg to list
        });
      }
    });
    setState(() { connectedId = id; status = "Connected!"; });
  }
}