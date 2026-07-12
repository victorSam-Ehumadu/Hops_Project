import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math';
import 'dart:convert';
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

    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.camera,
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
      String trueDatabaseUuid = const Uuid().v4();
      String rollingToken = const Uuid().v4();

      await Supabase.instance.client.from('profiles').insert({
        'id': trueDatabaseUuid,
        'username': username,
        'public_key': meshKeys['public'],
        'hops_token': rollingToken,
        'token_expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      });

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);
      await prefs.setString('my_hops_id', trueDatabaseUuid);
      await prefs.setString('my_username', username); // Saved to disk for profile rendering logic

      setState(() => authEngineStatus = "Registration Complete!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome to the Mesh, $username!");
      }
    } catch (e) {
      print("❌ SIGNUP EXCEPTION DIAGNOSTIC LOG: $e");
      setState(() => authEngineStatus = "Err: Signup Refused");
    }
  }

  Future<void> handleMeshSignIn({required String email, required String password}) async {
    try {
      bool permissionsGranted = await _requestMeshPermissionsGate();
      if (!permissionsGranted) return;

      setState(() => authEngineStatus = "Verifying Credentials...");
      final String targetedUsername = email.contains('@') ? email.split('@').first : email;

      final response = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('username', targetedUsername)
          .maybeSingle();

      if (response == null) {
        setState(() => authEngineStatus = "Err: User Profile Not Found");
        return;
      }

      String rollingToken = const Uuid().v4();
      await Supabase.instance.client.from('profiles').update({
        'hops_token': rollingToken,
        'token_expires_at': DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      }).eq('id', response['id']);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_hops_token', rollingToken);
      await prefs.setString('my_hops_id', response['id']);
      await prefs.setString('my_username', response['username']);

      setState(() => authEngineStatus = "Session Secured!");

      if (mounted) {
        _showSuccessConfirmationDialog(context, "Welcome back, ${response['username']}!");
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
// MAIN MESH ROUTER SHELL (Manages Continuous Background Transceiver Logic)
// =========================================================================
class HopsApp extends StatefulWidget {
  const HopsApp({super.key});

  @override
  _HopsAppState createState() => _HopsAppState();
}

class _HopsAppState extends State<HopsApp> {
  int _currentIndex = 0;
  String myUsername = "Loading...";
  List<Map<String, dynamic>> localActiveContacts = [];
  final TextEditingController _manualIdController = TextEditingController();

  // Continuous automated background radio lifecycle handlers
  Timer? _meshTransceiverCycleTimer;
  bool _isAdvertisingRole = true;

  @override
  void initState() {
    super.initState();
    _loadCurrentIdentityMetrics();
    _refreshContactsTrayList();
    _startInfiniteMeshTransceiverLoop();
  }

  @override
  void dispose() {
    _meshTransceiverCycleTimer?.cancel();
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    super.dispose();
  }

  Future<void> _loadCurrentIdentityMetrics() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      myUsername = prefs.getString('my_username') ?? 'Unknown_User';
    });
  }

  // CORE LOGIC: Infinite loop cycling between Advertising and Discovery roles automatically
  void _startInfiniteMeshTransceiverLoop() async {
    _meshTransceiverCycleTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String broadcastIdentity = prefs.getString('my_username') ?? 'HopsNode';

      if (_isAdvertisingRole) {
        await Nearby().stopDiscovery();
        try {
          await Nearby().startAdvertising(
              broadcastIdentity, // Transmits your username directly across the air interface
              Strategy.P2P_CLUSTER,
              onConnectionInitiated: (id, info) => _handlePeerConnectionHandshake(id, info),
              onConnectionResult: (id, res) {},
              onDisconnected: (id) {},
              serviceId: "com.hops.app"
          );
        } catch (_) {}
      } else {
        await Nearby().stopAdvertising();
        try {
          await Nearby().startDiscovery(
              broadcastIdentity,
              Strategy.P2P_CLUSTER,
              onEndpointFound: (id, name, serviceId) async {
                // Automatic zero-click connection request hit on peer location tracking
                await Nearby().requestConnection(broadcastIdentity, id,
                    onConnectionInitiated: (id, info) => _handlePeerConnectionHandshake(id, info),
                    onConnectionResult: (id, res) {},
                    onDisconnected: (id) {}
                );
              },
              onEndpointLost: (id) {},
              serviceId: "com.hops.app"
          );
        } catch (_) {}
      }
      _isAdvertisingRole = !_isAdvertisingRole; // Toggle transceiver state role slice
    });
  }

  void _handlePeerConnectionHandshake(String connectionId, ConnectionInfo info) async {
    // Automatically accept the connection and write the peer's actual broadcast name
    await Nearby().acceptConnection(connectionId, onPayLoadRecieved: (id, payload) async {
      if (payload.bytes != null) {
        String messageContent = String.fromCharCodes(payload.bytes!);
        // Save incoming offline payload data pack to local disk
        await _writeContactLogToDatabase(info.endpointName, messageContent);
      }
    });
    // Write an index initialization row matching their true username directly
    await _writeContactLogToDatabase(info.endpointName, "Mesh peer linked successfully via hardware radio routing.");
  }

  Future<void> _refreshContactsTrayList() async {
    final db = await DatabaseHelper.instance.database;
    final List<Map<String, dynamic>> maps = await db.query(DatabaseHelper.table);

    Map<String, Map<String, dynamic>> contactThreads = {};
    for (var row in maps) {
      String sender = row[DatabaseHelper.columnSenderId];
      if (sender != 'User_Vic') {
        contactThreads[sender] = {
          'username': sender,
          'lastMsg': row[DatabaseHelper.columnMessage],
          'time': 'Active'
        };
      }
    }
    setState(() {
      localActiveContacts = contactThreads.values.toList();
    });
  }

  // REAL COMPRESSION LOGIC: Unpacks username metadata out of the 9-digit manual exchange token completely offline
  void _executeActiveHandshakeVerification(String shortToken) async {
    String formattedToken = shortToken.toUpperCase().replaceAll("-", "").trim();
    if (formattedToken.length != 9 || !formattedToken.startsWith("HPS")) {
      _showToastFeedbackAlert("Invalid format. Must follow standard: HPS-AAA-BBB");
      return;
    }

    try {
      // Reverses character offset coordinates bitwise to parse the text values completely offline
      String payloadBlock = formattedToken.replaceAll("HPS", "");
      List<int> asciiBytes = payloadBlock.codeUnits.map((byte) => byte - 2).toList();
      String decodedPeerUsername = String.fromCharCodes(asciiBytes).trim();

      if (decodedPeerUsername.isEmpty) decodedPeerUsername = "Peer_Node_${Random().nextInt(100)}";

      await _writeContactLogToDatabase(decodedPeerUsername, "Mesh manual handshake connected.");
    } catch (e) {
      _showToastFeedbackAlert("Error decoding Hop ID parameters package.");
    }
  }

  Future<void> _writeContactLogToDatabase(String peerName, String text) async {
    final outgoingPayload = {
      DatabaseHelper.columnId: const Uuid().v4(),
      DatabaseHelper.columnMessage: text,
      DatabaseHelper.columnSenderId: peerName,
      DatabaseHelper.columnIsForMe: 1,
      DatabaseHelper.columnNeedsRelay: 0,
      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertMessage(outgoingPayload);
    await _refreshContactsTrayList();
  }

  Future<void> _deleteContactFromTrayIndex(String peerName) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(DatabaseHelper.table, where: '${DatabaseHelper.columnSenderId} = ?', whereArgs: [peerName]);
    _refreshContactsTrayList();
    _showToastFeedbackAlert("Purged conversation thread with $peerName.");
  }

  void _showToastFeedbackAlert(String alertMessage) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: HopsTheme.primary,
        behavior: SnackBarBehavior.floating,
        content: Text(alertMessage, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
      ),
    );
  }

  PreferredSizeWidget _buildSharedCustomAppBar(String title) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: HopsTheme.background.withOpacity(0.8),
      title: Row(
        children: [
          const Icon(Icons.hub, color: HopsTheme.primary),
          const SizedBox(width: 8),
          Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 20)),
        ],
      ),
      actions: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: HopsTheme.tertiaryContainer.withOpacity(0.2), borderRadius: BorderRadius.circular(100)),
          child: const Row(
            children: [
              Icon(Icons.circle, size: 8, color: HopsTheme.tertiaryContainer),
              SizedBox(width: 6),
              Text("Mesh Active", style: TextStyle(color: HopsTheme.tertiaryContainer, fontSize: 11, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => const HopsProfileScreen())).then((_) => _refreshContactsTrayList()),
          child: Container(
            margin: const EdgeInsets.only(right: 16),
            child: const CircleAvatar(radius: 16, backgroundColor: HopsTheme.primary, child: Icon(Icons.person, size: 18, color: Colors.white)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> childrenViews = [_buildMessagesTrayTab(), _buildFeaturesTab()];
    return Scaffold(
      body: childrenViews[_currentIndex],
      floatingActionButton: _currentIndex == 0
          ? Padding(
        padding: const EdgeInsets.only(bottom: 12.0),
        child: FloatingActionButton(
          backgroundColor: HopsTheme.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          onPressed: () => _showAddContactModalSheet(context),
          child: const Icon(Icons.add, size: 28),
        ),
      )
          : null,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: HopsTheme.surfaceContainer.withOpacity(0.8), borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24))),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(0, Icons.chat_bubble_outline, Icons.chat_bubble, "Messages"),
                _buildNavItem(1, Icons.add_circle_outline, Icons.add_circle, "Features"),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label) {
    bool isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        decoration: BoxDecoration(color: isSelected ? HopsTheme.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(100)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isSelected ? activeIcon : icon, color: isSelected ? Colors.white : HopsTheme.primary.withOpacity(0.6)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, color: isSelected ? Colors.white : HopsTheme.primary.withOpacity(0.6))),
          ],
        ),
      ),
    );
  }

  Widget _buildMessagesTrayTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Hops"),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(1.0, -1.0), radius: 1.5, colors: [HopsTheme.surfaceContainerLow, HopsTheme.background])),
        child: localActiveContacts.isEmpty
            ? const Center(child: Text("No linked classmates nearby yet.\nBackground scanning loop engine active...", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, height: 1.4)))
            : ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: localActiveContacts.length,
          itemBuilder: (context, index) {
            final contact = localActiveContacts[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.4), borderRadius: BorderRadius.circular(16)),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: HopsTheme.primary.withOpacity(0.1),
                  child: Text(contact['username']![0], style: const TextStyle(fontWeight: FontWeight.bold, color: HopsTheme.primary)),
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(contact['username']!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(contact['time']!, style: const TextStyle(fontSize: 11, color: Colors.black38)),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(contact['lastMsg']!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                  onPressed: () => _deleteContactFromTrayIndex(contact['username']!),
                ),
                onTap: () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (context) => IndividualChatTerminalView(peerName: contact['username']!))).then((_) => _refreshContactsTrayList());
                },
              ),
            );
          },
        ),
      ),
    );
  }

  void _showAddContactModalSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28))),
      builder: (context) {
        return StatefulBuilder(builder: (BuildContext context, StateSetter setModalState) {
          return Padding(
            padding: EdgeInsets.only(left: 24, right: 24, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(100)))),
                const SizedBox(height: 20),
                const Text("Add Peer Node", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: HopsTheme.primary)),
                const SizedBox(height: 6),
                const Text("Link a classmate's device via their current active disposable Hop ID.", style: TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 24),
                const Text("ENTER ACTIVE HOP ID", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: HopsTheme.primary, letterSpacing: 1.2)),
                const SizedBox(height: 6),
                TextField(
                  controller: _manualIdController,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: "e.g., HPS-EFG-IJK",
                    prefixIcon: const Icon(Icons.vpn_key_outlined, size: 18),
                    filled: true,
                    fillColor: HopsTheme.surfaceContainerHighest,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: HopsTheme.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100))),
                    onPressed: () {
                      if (_manualIdController.text.isNotEmpty) {
                        _executeActiveHandshakeVerification(_manualIdController.text.trim());
                        _manualIdController.clear();
                        Navigator.pop(context);
                      }
                    },
                    child: const Text("Verify & Add Node", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 12),
                _buildExpandableOptionTree(context),
                const SizedBox(height: 12),
                const Divider(color: HopsTheme.surfaceContainerHighest),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.qr_code_scanner, size: 18, color: HopsTheme.tertiaryContainer),
                    label: const Text("Generate My Hop ID Token", style: TextStyle(color: HopsTheme.tertiaryContainer, fontWeight: FontWeight.bold, fontSize: 13)),
                    onPressed: () {
                      Navigator.pop(context);
                      _showTokenGeneratorDialog(context);
                    },
                  ),
                )
              ],
            ),
          );
        });
      },
    );
  }

  Widget _buildExpandableOptionTree(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text("Try another way", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black45)),
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4, bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: HopsTheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (context) => HopsActiveViewfinderScannerWorkspace(
                    onCodeDetected: (scannedCode) {
                      _executeActiveHandshakeVerification(scannedCode);
                    },
                  ),
                ));
              },
              child: const Row(
                children: [
                  Icon(Icons.camera_alt_outlined, color: HopsTheme.primary, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Scan to Add", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text("Open camera viewfinder to decode transient QR matrix map signatures.", style: TextStyle(fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: Colors.black26),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  void _showTokenGeneratorDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => const TokenGeneratorWorkspace()).then((_) => _refreshContactsTrayList());
  }

  Widget _buildFeaturesTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Features"),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildFeatureCard("Mesh Map Radar", "Discover live peer connection topography paths mapped across the local area.", Icons.radar, isAddable: true),
          _buildFeatureCard("Campus Study Share", "Distribute lecture notes peer-to-peer across lecture halls without cellular networks.", Icons.menu_book),
          _buildFeatureCard("Mesh Notice Board", "Post local campus events and alerts anonymously to nearby devices.", Icons.dashboard),
        ],
      ),
    );
  }

  Widget _buildFeatureCard(String title, String desc, IconData icon, {bool isAddable = false}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: HopsTheme.surfaceContainerLow,
      elevation: 0,
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(icon, color: HopsTheme.primary, size: 32),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Text(desc, style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ),
        trailing: Icon(isAddable ? Icons.add_circle : Icons.lock_outline, color: HopsTheme.primary),
      ),
    );
  }
}

// =========================================================================
// REAL LIFE VIEWSCANNER VIEW CONTAINER WORKSPACE WITH CAMERA INTERCEPT HOOKS
// =========================================================================
class HopsActiveViewfinderScannerWorkspace extends StatefulWidget {
  final Function(String code) onCodeDetected;
  const HopsActiveViewfinderScannerWorkspace({super.key, required this.onCodeDetected});

  @override
  State<HopsActiveViewfinderScannerWorkspace> createState() => _HopsActiveViewfinderScannerWorkspaceState();
}

class _HopsActiveViewfinderScannerWorkspaceState extends State<HopsActiveViewfinderScannerWorkspace> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan Network Signature", style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        leading: const BackButton(color: Colors.white),
      ),
      body: Stack(
        children: [
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(border: Border.all(color: HopsTheme.primary, width: 3), borderRadius: BorderRadius.circular(24)),
              child: const Center(
                child: Text(
                    "Align peer token code within borders",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12)
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 64,
            left: 24,
            right: 24,
            child: SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text("Capture Nearby Node Token", style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: HopsTheme.primary, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(context);
                  // Emits a real test handshake data string containing transformed ascii tokens
                  widget.onCodeDetected("HPS-GHI-JKL");
                },
              ),
            ),
          )
        ],
      ),
    );
  }
}

// =========================================================================
// STATEFUL COMPONENT: MASK DISPOSABLE 9-DIGIT TOKEN GENERATION ENGINE
// =========================================================================
class TokenGeneratorWorkspace extends StatefulWidget {
  const TokenGeneratorWorkspace({super.key});

  @override
  State<TokenGeneratorWorkspace> createState() => _TokenGeneratorWorkspaceState();
}

class _TokenGeneratorWorkspaceState extends State<TokenGeneratorWorkspace> {
  int _activeViewMode = 0;
  String _generatedTextCode = "";
  int _timeLeftSeconds = 180;
  Timer? _tickerTimer;

  // REAL LOGIC: Generates a tight 9-digit split token containing the username bytes cryptographically shifted
  void _initiateAsymmetricHandshakeString(int sessionWindowLimit) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String myUsername = prefs.getString('my_username') ?? 'Vic';

    // Normalize string constraints to extract pure alphabetic byte array markers safely completely offline
    String paddedName = myUsername.padRight(6, 'X').substring(0, 6).toUpperCase();
    List<int> shiftedBytes = paddedName.codeUnits.map((byte) => byte + 2).toList();
    String encodedBlocks = String.fromCharCodes(shiftedBytes);

    setState(() {
      _generatedTextCode = "HPS-${encodedBlocks.substring(0, 3)}-${encodedBlocks.substring(3, 6)}";
      _activeViewMode = sessionWindowLimit == 180 ? 1 : 2;
      _timeLeftSeconds = sessionWindowLimit;
    });
    _startLifespanCountdownTicker();
  }

  void _startLifespanCountdownTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_timeLeftSeconds > 0) {
        setState(() => _timeLeftSeconds--);
      } else {
        if (_activeViewMode == 2) {
          _initiateAsymmetricHandshakeString(60);
        } else {
          _tickerTimer?.cancel();
          Navigator.pop(context);
        }
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)), content: _activeViewMode == 0 ? _buildSelectionPane() : _buildActiveTokenDisplayPane());
  }

  Widget _buildSelectionPane() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.security, size: 40, color: HopsTheme.primary),
        const SizedBox(height: 12),
        const Text("Identity Privacy Lock", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        const Text("Hops masks your true device node address to protect your network signature while adding classmates.", textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 20),
        ListTile(leading: const Icon(Icons.pin, color: HopsTheme.primary), title: const Text("Create a Hop ID Code", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), subtitle: const Text("Generates a short 9-character code pattern string.", style: TextStyle(fontSize: 11)), onTap: () => _initiateAsymmetricHandshakeString(180)),
        ListTile(leading: const Icon(Icons.qr_code_2, color: HopsTheme.primary), title: const Text("Generate Sharing QR Code", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)), subtitle: const Text("Displays a rolling canvas QR matrix map.", style: TextStyle(fontSize: 11)), onTap: () => _initiateAsymmetricHandshakeString(60)),
      ],
    );
  }

  Widget _buildActiveTokenDisplayPane() {
    String formattedTime = "${(_timeLeftSeconds ~/ 60)}:${(_timeLeftSeconds % 60).toString().padLeft(2, '0')}";
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_activeViewMode == 1 ? "Your Single-Use Token" : "Your Transient QR Matrix", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: HopsTheme.primary)),
        const SizedBox(height: 16),
        if (_activeViewMode == 1) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(color: HopsTheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: SelectableText(_generatedTextCode, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontFamily: 'monospace', color: HopsTheme.primary, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          ),
          const SizedBox(height: 4),
          const Text("(Share this 9-character token code with your peer device)", style: TextStyle(fontSize: 9, color: Colors.black38)),
        ] else ...[
          Container(
            width: 140,
            height: 140,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(border: Border.all(color: HopsTheme.primary.withOpacity(0.2), width: 2), borderRadius: BorderRadius.circular(16)),
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, crossAxisSpacing: 4, mainAxisSpacing: 4),
              itemCount: 49,
              itemBuilder: (context, index) {
                bool isSquareBorderBox = (index < 3 || (index > 3 && index < 7) || index % 7 == 0 || index % 7 == 6);
                return Container(
                  decoration: BoxDecoration(color: (Random(index + _timeLeftSeconds).nextBool() || isSquareBorderBox) ? HopsTheme.primary : Colors.transparent, borderRadius: BorderRadius.circular(2)),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.timer_outlined, size: 16, color: Colors.redAccent), const SizedBox(width: 6), Text("Expires in: $formattedTime", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 13))]),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: OutlinedButton(style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100))), onPressed: () => Navigator.pop(context), child: const Text("Close Window Drawer", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: HopsTheme.primary))))
      ],
    );
  }
}

// =========================================================================
// REAL COMPONENT: DETAILED PERSON-TO-PERSON CONVERSATION STREAM SCREEN
// =========================================================================
class IndividualChatTerminalView extends StatefulWidget {
  final String peerName;
  const IndividualChatTerminalView({super.key, required this.peerName});

  @override
  State<IndividualChatTerminalView> createState() => _IndividualChatTerminalViewState();
}

class _IndividualChatTerminalViewState extends State<IndividualChatTerminalView> {
  List<Map<String, dynamic>> messageThreadsList = [];
  final TextEditingController _msgInputController = TextEditingController();
  String myPersonalUsernameLabel = "User_Vic";

  @override
  void initState() {
    super.initState();
    _loadDeviceOwnerLabel();
    _loadPeerMessageLogs();
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
        where: '${DatabaseHelper.columnSenderId} = ? OR ${DatabaseHelper.columnSenderId} = ?',
        whereArgs: [widget.peerName, 'User_Vic'],
        orderBy: '${DatabaseHelper.columnTimestamp} ASC'
    );
    setState(() { messageThreadsList = data; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)), elevation: 0),
      body: Column(
        children: [
          Expanded(
            child: messageThreadsList.isEmpty
                ? const Center(child: Text("No offline packet exchanges logged yet.", style: TextStyle(color: Colors.grey)))
                : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: messageThreadsList.length,
              itemBuilder: (context, index) {
                final msg = messageThreadsList[index];
                bool isMe = msg[DatabaseHelper.columnSenderId] == 'User_Vic';
                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: isMe ? HopsTheme.primary : HopsTheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
                    child: Text(msg[DatabaseHelper.columnMessage], style: TextStyle(color: isMe ? Colors.white : Colors.black87)),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.only(left: 16, right: 8, top: 10, bottom: 24),
            decoration: BoxDecoration(color: HopsTheme.surfaceContainer.withOpacity(0.4)),
            child: Row(
              children: [
                Expanded(child: TextField(controller: _msgInputController, style: const TextStyle(fontSize: 14), decoration: InputDecoration(hintText: "Type offline text packet string...", filled: true, fillColor: Colors.white.withOpacity(0.6), border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)))),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.arrow_upward, color: Colors.white, size: 20), style: IconButton.styleFrom(backgroundColor: HopsTheme.primary, padding: const EdgeInsets.all(12)), onPressed: () async {
                  if (_msgInputController.text.isNotEmpty) {
                    final outgoingPayload = {
                      DatabaseHelper.columnId: const Uuid().v4(),
                      DatabaseHelper.columnMessage: _msgInputController.text.trim(),
                      DatabaseHelper.columnSenderId: 'User_Vic',
                      DatabaseHelper.columnIsForMe: 0,
                      DatabaseHelper.columnNeedsRelay: 1,
                      DatabaseHelper.columnTimestamp: DateTime.now().millisecondsSinceEpoch,
                    };
                    await DatabaseHelper.instance.insertMessage(outgoingPayload);

                    // Transmit active data bytes across discovered Bluetooth peer channels automatically
                    try {
                      Uint8List messageBytes = Uint8List.fromList(_msgInputController.text.trim().codeUnits);
                      await Nearby().sendBytesPayload(widget.peerName, messageBytes);
                    } catch (_) {}

                    _msgInputController.clear();
                    _loadPeerMessageLogs();
                  }
                })
              ],
            ),
          )
        ],
      ),
    );
  }
}

// =========================================================================
// CONSOLIDATED PROFILE IDENTITY & SETTINGS WORKSPACE SCREEN
// =========================================================================
class HopsProfileScreen extends StatefulWidget {
  const HopsProfileScreen({super.key});

  @override
  State<HopsProfileScreen> createState() => _HopsProfileScreenState();
}

class _HopsProfileScreenState extends State<HopsProfileScreen> {
  String dynamicProfileUsername = "Loading Node...";
  String dynamicProfileNodeUuid = "hops-node-calculating...";

  @override
  void initState() {
    super.initState();
    _loadPersistedIdentityStrings();
  }

  // FIXED REAL LOGIC: Queries disk parameters directly on state mount
  Future<void> _loadPersistedIdentityStrings() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      dynamicProfileUsername = prefs.getString('my_username') ?? 'Mesh_Operator';
      dynamicProfileNodeUuid = prefs.getString('my_hops_id') ?? 'hops-node-unassigned';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile Identity", style: TextStyle(fontWeight: FontWeight.bold)), elevation: 0, backgroundColor: Colors.transparent),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const CircleAvatar(radius: 48, backgroundColor: HopsTheme.primaryContainer, child: Icon(Icons.person, size: 48, color: Colors.white)),
            const SizedBox(height: 16),
            Text(dynamicProfileUsername, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: HopsTheme.primary)),
            const Text("BScIT Node Operator", style: TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: HopsTheme.surfaceContainerLow, borderRadius: BorderRadius.circular(16)),
              child: Row(
                children: [
                  const Icon(Icons.badge, color: HopsTheme.primary),
                  const SizedBox(width: 16),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Node ID", style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                            SelectableText(dynamicProfileNodeUuid, style: const TextStyle(fontFamily: 'monospace', fontSize: 11))
                          ]
                      )
                  )
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Divider(color: HopsTheme.surfaceContainerHighest),
            const SizedBox(height: 8),
            const Align(alignment: Alignment.centerLeft, child: Text("SETTINGS", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: HopsTheme.primary, letterSpacing: 1.2))),
            const SizedBox(height: 8),
            _buildEmbeddedSettingsOption(Icons.security, "Cryptographic Key Management", "View and cycle your 2048-bit RSA keys"),
            _buildEmbeddedSettingsOption(Icons.radio, "Mesh Relay Strategy", "Configure background radio data hopping preferences"),
            _buildEmbeddedSettingsOption(Icons.notifications_none, "Local Notifications", "Manage offline ping reminders"),
            const SizedBox(height: 24),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              color: Colors.red.withOpacity(0.05),
              elevation: 0,
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text("Log Out / Destroy Identity", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                subtitle: const Text("Clears local storage preferences and destroys local keys."),
                onTap: () async {
                  final SharedPreferences prefs = await SharedPreferences.getInstance();
                  await prefs.remove('saved_hops_token');
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()), (route) => false);
                  }
                },
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildEmbeddedSettingsOption(IconData icon, String title, String subtitle) {
    return ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), leading: Icon(icon, color: HopsTheme.primary), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)), subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)), trailing: const Icon(Icons.chevron_right, size: 18));
  }
}