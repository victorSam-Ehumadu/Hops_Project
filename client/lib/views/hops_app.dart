import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/theme/hops_theme.dart';
import 'package:client/utils/hop_id_formatter.dart';
import 'package:client/views/radar_screen.dart';
import 'package:client/views/chat_terminal.dart';
import 'package:client/views/viewfinder_scanner.dart';
import 'package:client/views/token_generator.dart';
import 'package:client/views/profile_screen.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/models/feature_item.dart';
import 'package:client/views/half_wheel.dart';

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

  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  bool _bleInitialized = false;

  String? _activePairingCode;
  Timer? _pairingTimeout;

  // Radar stream
  final _radarStreamController = StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get radarStream => _radarStreamController.stream;

  // Feature toggles
  final Set<int> enabledFeatureIds = {};

  // Friend request management (NEW – replaces the old stream/dialog)
  final List<String> pendingRequests = [];
  final Set<String> _processingAccepts = {};
  Set<String> get friendUsernames =>
      localActiveContacts.map((c) => c['username'] as String).toSet();

  @override
  void initState() {
    super.initState();
    _loadCurrentIdentityMetrics();
    _checkPermissionsAndStartBLE();
    // No dialog listener – friend requests are now shown as cards
  }

  @override
  void dispose() {
    _bleScanResultsSubscription?.cancel();
    FlutterBluePlus.stopScan();
    BlePeripheral.stopAdvertising();
    _cleanupPairingServer();
    _radarStreamController.close();
    super.dispose();
  }

  // --------------- Friend request logic ---------------
  Future<void> sendFriendRequest(String targetUsername) async {
    if (friendUsernames.contains(targetUsername)) {
      _showToastFeedbackAlert("$targetUsername is already your friend");
      return;
    }
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: "FRIEND_REQ:$targetUsername:$myUsername",
      services: [],
    );
    Future.delayed(const Duration(seconds: 10), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(
        localName: "HPS:$myUsername",
        services: [],
      );
    });
  }

  Future<void> acceptFriendRequest(String sender) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: "FRIEND_ACK:$sender:$myUsername",
      services: [],
    );
    await _writeContactLogToDatabase(sender, "Friend added via radar");
    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(
        localName: "HPS:$myUsername",
        services: [],
      );
    });
  }

  void acceptRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() {
      pendingRequests.remove(sender);
    });
    acceptFriendRequest(sender).then((_) {
      _processingAccepts.remove(sender);
    });
  }

  void declineRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() {
      pendingRequests.remove(sender);
    });
    // Nothing more to do for decline, just remove from processing after a short delay
    Future.delayed(const Duration(seconds: 2), () {
      _processingAccepts.remove(sender);
    });
  }

  // --------------- Permissions & BLE setup ---------------
  Future<void> _checkPermissionsAndStartBLE() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    bool granted = statuses[Permission.location]!.isGranted && statuses[Permission.bluetoothScan]!.isGranted;
    if (!granted) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const HopsRootGatekeeper()),
              (route) => false,
        );
      }
      return;
    }
    _initializeParallelBleTransceiverEngine();
  }

  Future<void> _loadCurrentIdentityMetrics() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      myUsername = prefs.getString('my_username') ?? 'Unknown_User';
    });
  }

  void _initializeParallelBleTransceiverEngine() async {
    if (_bleInitialized) return;
    _bleInitialized = true;

    await BlePeripheral.initialize();
    await BlePeripheral.startAdvertising(
      localName: "HPS:$myUsername",
      services: [],
    );

    _bleScanResultsSubscription = FlutterBluePlus.scanResults.listen((results) async {
      _radarStreamController.add(results);

      for (ScanResult r in results) {
        String name = r.advertisementData.advName;

        // ACK handling
        if (name.startsWith("ACK:") && _activePairingCode != null) {
          List<String> parts = name.substring(4).split(":");
          if (parts.length == 2 && parts[0] == _activePairingCode) {
            String remoteUsername = parts[1];
            bool exists = localActiveContacts.any((c) => c['username'] == remoteUsername);
            if (!exists) {
              await _writeContactLogToDatabase(remoteUsername, "Mutual pairing via code");
            }
          }
        }

        // Friend request handling (NEW – adds to pendingRequests)
        if (name.startsWith("FRIEND_REQ:")) {
          List<String> parts = name.substring(11).split(":");
          if (parts.length == 2) {
            String target = parts[0];
            String sender = parts[1];
            if (target == myUsername) {
              if (!friendUsernames.contains(sender) &&
                  !pendingRequests.contains(sender) &&
                  !_processingAccepts.contains(sender)) {
                setState(() {
                  pendingRequests.add(sender);
                });
              }
            }
          }
        }

        // Friend ACK handling
        if (name.startsWith("FRIEND_ACK:")) {
          List<String> parts = name.substring(11).split(":");
          if (parts.length == 2) {
            String target = parts[0];
            String sender = parts[1];
            if (target == myUsername) {
              await _writeContactLogToDatabase(sender, "Friend added via radar");
            }
          }
        }
      }
    });

    await _startContinuousScan();
  }

  Future<void> _stopAllAdvertising() async {
    await BlePeripheral.stopAdvertising();
  }

  Future<void> _startContinuousScan() async {
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      continuousUpdates: true,
    );
  }

  // --------------- Existing pairing (code) ---------------
  void _startPairingServer(String code) {
    _activePairingCode = code;
    BlePeripheral.stopAdvertising().then((_) {
      BlePeripheral.startAdvertising(
        localName: "HOP:$code:$myUsername",
        services: [],
      );
    });
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(const Duration(seconds: 180), () {
      _cleanupPairingServer();
    });
  }

  void _cleanupPairingServer() {
    _pairingTimeout?.cancel();
    if (_activePairingCode != null) {
      _stopAllAdvertising();
      _activePairingCode = null;
    }
  }

  Future<void> _startPairingClient(String code) async {
    await FlutterBluePlus.stopScan();
    Completer<String?> completer = Completer<String?>();
    StreamSubscription<List<ScanResult>> sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        String name = r.advertisementData.advName;
        if (name.startsWith("HOP:$code:")) {
          String remoteUsername = name.substring(("HOP:$code:").length);
          completer.complete(remoteUsername);
        }
      }
    });
    await FlutterBluePlus.startScan(androidUsesFineLocation: true);
    String? remoteUsername;
    try {
      remoteUsername = await completer.future.timeout(const Duration(seconds: 30));
    } catch (_) {}
    await sub.cancel();
    await FlutterBluePlus.stopScan();

    if (remoteUsername == null) {
      _showToastFeedbackAlert("Device not found. Ensure the code is active on the other device.");
      return;
    }
    await _writeContactLogToDatabase(remoteUsername, "Mutual pairing via code");
    await _sendAck(code);
    _showToastFeedbackAlert("Connected with $remoteUsername!");
    await _startContinuousScan();
  }

  Future<void> _sendAck(String code) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: "ACK:$code:$myUsername",
      services: [],
    );
    Future.delayed(const Duration(seconds: 5), () {
      if (_activePairingCode == null) {
        _stopAllAdvertising();
      }
    });
  }

  // --------------- Contacts management ---------------
  Future<void> _refreshContactsTrayList() async {
    final db = await DatabaseHelper.instance.database;
    final List<Map<String, dynamic>> maps = await db.query(DatabaseHelper.table);
    Map<String, Map<String, dynamic>> contactThreads = {};
    for (var row in maps) {
      String sender = row[DatabaseHelper.columnSenderId];
      if (sender != myUsername) {
        contactThreads[sender] = {
          'username': sender,
          'lastMsg': row[DatabaseHelper.columnMessage],
          'time': 'Nearby'
        };
      }
    }
    setState(() {
      localActiveContacts = contactThreads.values.toList();
    });
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

  void _executeActiveHandshakeVerification(String code) async {
    String formatted = code.toUpperCase().trim();
    if (!formatted.startsWith("HPS-") || formatted.length != 11) {
      _showToastFeedbackAlert("Invalid format. Use HPS-XXX-YYY.");
      return;
    }
    String rawCode = formatted.replaceAll("HPS-", "").replaceAll("-", "");
    if (rawCode.length != 6) {
      _showToastFeedbackAlert("Code must be 6 alphanumeric characters.");
      return;
    }
    await _startPairingClient(rawCode);
  }

  // --------------- Feature toggling ---------------
  void _toggleFeature(int featureId) {
    setState(() {
      if (enabledFeatureIds.contains(featureId)) {
        enabledFeatureIds.remove(featureId);
      } else {
        enabledFeatureIds.add(featureId);
      }
    });
  }

  // --------------- UI ---------------
  PreferredSizeWidget _buildSharedCustomAppBar(String title) {
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: HopsTheme.background.withOpacity(0.8),
      title: Row(
        children: [
          const Icon(Icons.bluetooth_audio, color: HopsTheme.primary),
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
              Icon(Icons.radar, size: 12, color: HopsTheme.tertiaryContainer),
              SizedBox(width: 6),
              Text("BLE Mesh Active", style: TextStyle(color: HopsTheme.tertiaryContainer, fontSize: 11, fontWeight: FontWeight.bold)),
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
    final List<Widget> tabs = [
      RadarScreen(
        radarStream: radarStream,
        onSendFriendRequest: sendFriendRequest,
        pendingRequests: pendingRequests,
        onAcceptRequest: acceptRequest,
        onDeclineRequest: declineRequest,
        friendUsernames: friendUsernames,
      ),
      _buildContactsTab(),
      _buildFeaturesTab(),
    ];

    final bool showBunny = enabledFeatureIds.isNotEmpty;

    return Stack(
      children: [
        Scaffold(
          body: tabs[_currentIndex],
          floatingActionButton: _currentIndex == 1
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
            decoration: BoxDecoration(
              color: HopsTheme.surfaceContainer.withOpacity(0.8),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(24),
                topRight: Radius.circular(24),
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildNavItem(0, Icons.radar, Icons.radar, "Radar"),
                    _buildNavItem(1, Icons.people_outline, Icons.people, "Contacts"),
                    _buildNavItem(2, Icons.grid_view_outlined, Icons.grid_view, "Features"),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Bunny icon overlay
        if (showBunny)
          Positioned(
            bottom: 90,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: () {
                  final enabledFeatures =
                  allFeatures.where((f) => enabledFeatureIds.contains(f.id)).toList();
                  showModalBottomSheet(
                    context: context,
                    builder: (_) => HalfWheelPicker(
                      features: enabledFeatures,
                      onSelected: (feature) {
                        if (feature.pageBuilder != null) {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => feature.pageBuilder!()),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text("${feature.name} page not built yet"),
                            ),
                          );
                        }
                      },
                    ),
                  );
                },
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: HopsTheme.primary,
                    boxShadow: [
                      BoxShadow(
                        color: HopsTheme.primary.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Text(
                      '🐰',
                      style: TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label) {
    bool isSelected = _currentIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? HopsTheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
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

  Widget _buildContactsTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Contacts"),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(1.0, -1.0), radius: 1.5, colors: [HopsTheme.surfaceContainerLow, HopsTheme.background])),
        child: localActiveContacts.isEmpty
            ? const Center(child: Text("No contacts yet.\nEnter a pairing code to connect.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, height: 1.4)))
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
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => IndividualChatTerminalView(
                        peerName: contact['username']!,
                        onSendMessage: (recipient, message) async {},
                      ),
                    ),
                  ).then((_) => _refreshContactsTrayList());
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
                const Text("Enter the 6‑character pairing code shown on your classmate's device.", style: TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 24),
                const Text("ENTER PAIRING CODE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: HopsTheme.primary, letterSpacing: 1.2)),
                const SizedBox(height: 6),
                TextField(
                  controller: _manualIdController,
                  autofocus: true,
                  inputFormatters: [HopIdInputFormatter()],
                  style: const TextStyle(fontSize: 14, fontFamily: 'monospace', letterSpacing: 1.2),
                  decoration: InputDecoration(
                    hintText: "HPS-XXX-YYY",
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
                      if (_manualIdController.text.length == 11) {
                        _executeActiveHandshakeVerification(_manualIdController.text.trim());
                        _manualIdController.clear();
                        Navigator.pop(context);
                      } else {
                        _showToastFeedbackAlert("Code must be fully typed (HPS-XXX-YYY)");
                      }
                    },
                    child: const Text("Connect", style: TextStyle(fontWeight: FontWeight.bold)),
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
                    label: const Text("Generate My Pairing Code", style: TextStyle(color: HopsTheme.tertiaryContainer, fontWeight: FontWeight.bold, fontSize: 13)),
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
    showDialog(context: context, builder: (context) => TokenGeneratorWorkspace(
      onCodeGenerated: (code) {
        _startPairingServer(code);
      },
    )).then((_) => _refreshContactsTrayList());
  }

  Widget _buildFeaturesTab() {
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Features"),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: allFeatures.length,
        itemBuilder: (context, index) {
          final feature = allFeatures[index];
          final isEnabled = enabledFeatureIds.contains(feature.id);
          return _buildFeatureCard(feature, isEnabled);
        },
      ),
    );
  }

  Widget _buildFeatureCard(FeatureItem feature, bool isEnabled) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: HopsTheme.surfaceContainerLow,
      elevation: 0,
      child: ExpansionTile(
        leading: Icon(feature.icon, color: HopsTheme.primary, size: 28),
        title: Text(
          feature.name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text(
          feature.shortDesc,
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              feature.longDesc,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 12),
              child: ElevatedButton.icon(
                icon: Icon(
                  isEnabled ? Icons.check_circle : Icons.add_circle_outline,
                  size: 18,
                ),
                label: Text(isEnabled ? "Added" : "Add"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isEnabled
                      ? HopsTheme.tertiaryContainer.withOpacity(0.3)
                      : HopsTheme.primary,
                  foregroundColor: isEnabled ? HopsTheme.primary : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                onPressed: () => _toggleFeature(feature.id),
              ),
            ),
          ),
        ],
      ),
    );
  }
}