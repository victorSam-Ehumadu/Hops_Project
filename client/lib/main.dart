import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:crypton/crypton.dart';
import 'package:client/views/auth_screen.dart';
import 'package:client/theme/hops_theme.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? savedToken = prefs.getString('saved_hops_token');

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HopsTheme.lightTheme,
    home: savedToken != null ? const HopsApp() : const HopsRootGatekeeper(),
  ));
}

// =========================================================================
// MESH SESSION GATEKEEPER (Handles Onboarding -> Cloud Database Handshake)
// =========================================================================
class HopsRootGatekeeper extends StatefulWidget {
  const HopsRootGatekeeper({super.key});

  @override
  State<HopsRootGatekeeper> createState() => _HopsRootGatekeeperState();
}

class _HopsRootGatekeeperState extends State<HopsRootGatekeeper> {
  String authEngineStatus = "System Ready";

  Future<bool> _requestMeshPermissionsGate() async {
    setState(() => authEngineStatus = "Awaiting System Permissions...");

    // Request required high-security platform permission metrics explicitly
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    if (statuses[Permission.location]!.isGranted) {
      return true;
    } else {
      setState(() => authEngineStatus = "Err: Permissions Denied");
      return false;
    }
  }

  Map<String, String> _generateLocalMeshKeys() {
    RSAKeypair keypair = RSAKeypair.fromRandom();
    return {'public': keypair.publicKey.toString(), 'private': keypair.privateKey.toString()};
  }

  Future<void> handleMeshSignUp({required String email, required String password, required String username}) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Generating Crypto Keys...");
      final meshKeys = _generateLocalMeshKeys();

      setState(() => authEngineStatus = "Registering Identity...");
      String clientSideUuid = const Uuid().v4();
      String rollingToken = const Uuid().v4();
      DateTime expirationTime = DateTime.now().add(const Duration(hours: 24));

      await Supabase.instance.client.from('profiles').insert({
        'id': clientSideUuid,
        'username': username,
        'public_key': meshKeys['public'],
        'hops_token': rollingToken,
        'token_expires_at': expirationTime.toIso8601String(),
      });

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);

      setState(() => authEngineStatus = "Registration Complete!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome to the Mesh, $username! Your local cryptographic identity node is secure.");
      }
    } catch (e) {
      setState(() => authEngineStatus = "Err: Signup Refused");
    }
  }

  Future<void> handleMeshSignIn({required String email, required String password}) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Verifying Credentials...");

      // Pull matching node username string from database records cleanly
      final String targetedUsername = email.contains('@') ? email.split('@').first : email;

      final response = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('username', targetedUsername)
          .maybeSingle();

      if (response == null) {
        setState(() => authEngineStatus = "Err: User Profile Not Found");
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No mesh profile matches that student identity.")));
        return;
      }

      String rollingToken = const Uuid().v4();
      await Supabase.instance.client.from('profiles').update({
        'hops_token': rollingToken,
        'token_expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      }).eq('id', response['id']);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);

      setState(() => authEngineStatus = "Session Secured!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome back, ${response['username']}! Mesh validation verified successfully.");
      }
    } catch (e) {
      setState(() => authEngineStatus = "Err: Authentication Aborted");
    }
  }

  void _showSuccessConfirmationDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: HopsTheme.tertiaryContainer),
            SizedBox(width: 8),
            Text("Success", style: TextStyle(color: HopsTheme.primary, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(color: HopsTheme.onBackground)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (context) => const HopsApp()));
            },
            child: const Text("Enter Dashboard", style: TextStyle(color: HopsTheme.primary, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScreen(
      currentStatus: authEngineStatus,
      onSignUpTrigger: handleMeshSignUp,
      onSignInTrigger: handleMeshSignIn,
    );
  }
}

// =========================================================================
// MAIN MESH MESSENGER DASHBOARD (Sade's Premium Glass Aesthetics Refactor)
// =========================================================================
class HopsApp extends StatefulWidget {
  const HopsApp({super.key});

  @override
  _HopsAppState createState() => _HopsAppState();
}

class _HopsAppState extends State<HopsApp> {
  String status = "Offline";
  List<Map<String, dynamic>> databaseMessages = [];
  final TextEditingController _msgController = TextEditingController();
  String? connectedId;
  final Uuid _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _loadMessagesFromDB();

    // Trigger Bluetooth check cleanly after the layout components complete their initial paint frames
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkHardwareBluetoothState();
    });
  }

  void _checkHardwareBluetoothState() async {
    if (Platform.isAndroid) {
      // Direct local validation loop mapping via native advertising routines
      try {
        await Nearby().startAdvertising(
            "User_Vic",
            Strategy.P2P_CLUSTER,
            onConnectionInitiated: (id, info) {},
            onConnectionResult: (id, res) {},
            onDisconnected: (id) {},
            serviceId: "com.hops.app"
        );
        await Nearby().stopAdvertising();
      } catch (e) {
        // If startAdvertising fails directly, it indicates the physical Bluetooth switch is disabled
        _showBluetoothHardwareAlert();
      }
    }
  }

  void _showBluetoothHardwareAlert() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.redAccent),
            SizedBox(width: 8),
            Text("Bluetooth Off", style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text("Hops operates completely decentralized. Please switch on your hardware Bluetooth radio interface in system preferences to discover peer campus nodes."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Dismiss", style: TextStyle(color: HopsTheme.primary, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

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
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: HopsTheme.background.withOpacity(0.8),
        title: Row(
          children: [
            const Icon(Icons.hub, color: HopsTheme.primary),
            const SizedBox(width: 8),
            Text("Hops", style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 20)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: HopsTheme.tertiaryContainer.withOpacity(0.2),
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: HopsTheme.tertiaryContainer, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                const Text("12 Nodes Nearby", style: TextStyle(color: HopsTheme.tertiaryContainer, fontSize: 11, fontWeight: FontWeight.bold)),
              ],
            ),
          )
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [HopsTheme.surfaceContainerLow, HopsTheme.background],
          ),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.4), borderRadius: BorderRadius.circular(16)),
              child: const Row(
                children: [
                  Icon(Icons.cell_tower, color: HopsTheme.primary, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Hopping through 4 peers to reach the campus node.",
                      style: TextStyle(fontSize: 12, color: HopsTheme.onBackground, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: databaseMessages.isEmpty
                  ? Center(
                child: Opacity(
                  opacity: 0.4,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.forum_outlined, size: 48, color: HopsTheme.primary),
                      const SizedBox(height: 12),
                      Text("No active node data logging.", style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 14)),
                    ],
                  ),
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: databaseMessages.length,
                itemBuilder: (context, index) {
                  final msg = databaseMessages[index];
                  bool isMeSender = msg[DatabaseHelper.columnSenderId] == 'User_Vic';

                  return Align(
                    alignment: isMeSender ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                      decoration: BoxDecoration(
                        gradient: isMeSender ? const LinearGradient(colors: [HopsTheme.primary, HopsTheme.primaryContainer]) : null,
                        color: isMeSender ? null : HopsTheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(isMeSender ? 16 : 4),
                          bottomRight: Radius.circular(isMeSender ? 4 : 16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: isMeSender ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Text(
                            msg[DatabaseHelper.columnMessage],
                            style: TextStyle(fontSize: 14, color: isMeSender ? Colors.white : HopsTheme.onBackground, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isMeSender ? "Sent via Mesh" : "Node: ${msg[DatabaseHelper.columnSenderId]}",
                            style: TextStyle(fontSize: 9, color: isMeSender ? Colors.white70 : Colors.black45, fontWeight: FontWeight.bold),
                          )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.wifi_find, size: 16),
                      label: Text("Listen: $status", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: HopsTheme.primary,
                        side: const BorderSide(color: HopsTheme.surfaceContainerHighest, width: 1.5),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      ),
                      onPressed: () => startDiscovery(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.radar, size: 16),
                      label: const Text("Beacon", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: HopsTheme.tertiaryContainer,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                      ),
                      onPressed: () => startAdvertising(),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 24),
              decoration: BoxDecoration(
                color: HopsTheme.surfaceContainer.withOpacity(0.4),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: "Send encrypted packet...",
                        hintStyle: const TextStyle(color: Colors.black38),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.6),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: Colors.white, size: 20),
                    style: IconButton.styleFrom(backgroundColor: HopsTheme.primary, padding: const EdgeInsets.all(12)),
                    onPressed: () async {
                      if (_msgController.text.isNotEmpty) {
                        String textToSend = _msgController.text;
                        String uniqueMsgId = _uuid.v4();

                        final outgoingPayload = {
                          DatabaseHelper.columnId: uniqueMsgId,
                          DatabaseHelper.columnMessage: textToSend,
                          DatabaseHelper.columnSenderId: 'User_Vic',
                          DatabaseHelper.columnIsForMe: 0,
                          DatabaseHelper.columnNeedsRelay: 1,
                          DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
                        };

                        await DatabaseHelper.instance.insertMessage(outgoingPayload);
                        _loadMessagesFromDB();

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

        final incomingPayload = {
          DatabaseHelper.columnId: _uuid.v4(),
          DatabaseHelper.columnMessage: decodedString,
          DatabaseHelper.columnSenderId: id,
          DatabaseHelper.columnIsForMe: 1,
          DatabaseHelper.columnNeedsRelay: 0,
          DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
        };

        await DatabaseHelper.instance.insertMessage(incomingPayload);
        _loadMessagesFromDB();
      }
    });
    setState(() { connectedId = id; status = "Connected!"; });
  }
}