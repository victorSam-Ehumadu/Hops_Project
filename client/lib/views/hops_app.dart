import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:client/database/database_helper.dart';
// No more import of hops_theme.dart
import 'package:client/utils/hop_id_formatter.dart';
import 'package:client/views/radar_screen.dart';
import 'package:client/views/chat_terminal.dart';
import 'package:client/views/viewfinder_scanner.dart';
import 'package:client/views/token_generator.dart';
import 'package:client/views/profile_screen.dart';
import 'package:client/views/root_gatekeeper.dart';
import 'package:client/models/feature_item.dart';
import 'package:client/views/vibe_check_page.dart';
import 'package:client/views/watch_me_page.dart';
import 'package:client/views/hops_and_robbers.dart';
import 'package:client/views/task_tracker_page.dart';
import 'package:client/views/hops_share_page.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/chat_connection_service.dart';
import 'package:client/services/hops_constants.dart';

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

  bool _isFlareActive = false;
  Timer? _flareCancelTimer;
  Timer? _scanRestartTimer;

  String? _myAvatarPath;

  DateTime _lastRadarPush = DateTime(2000);   // force immediate first push

  StreamSubscription<List<ScanResult>>? _bleScanResultsSubscription;
  bool _bleInitialized = false;

  String? _activePairingCode;
  Timer? _pairingTimeout;

  // Diagnostic counters
  int _totalScanResults = 0;
  final Set<String> _uniqueHopsDevices = {};
  Timer? _diagTimer;

  // Radar stream
  final _radarStreamController = StreamController<List<ScanResult>>.broadcast();
  Stream<List<ScanResult>> get radarStream => _radarStreamController.stream;

  // At the top, next to the other sets
  final Set<String> _handledWatchAcks = {};

  final _gameEventStreamController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get gameEventStream => _gameEventStreamController.stream;

  // Watch request stream
  late final StreamController<List<String>> _pendingWatchStreamController;
  Stream<List<String>> get pendingWatchStream => _pendingWatchStreamController.stream;

  // Active buddies stream
  late final StreamController<Set<String>> _watchingBuddiesStreamController;
  Stream<Set<String>> get watchingBuddiesStream => _watchingBuddiesStreamController.stream;

  // Feature toggles
  Set<int> enabledFeatureIds = {};

  // Friend request management
  final List<String> pendingRequests = [];
  final Set<String> _processingAccepts = {};
  Set<String> get friendUsernames =>
      localActiveContacts.map((c) => c['username'] as String).toSet();

  // Watch Me state
  Set<String> _watchingBuddies = {};
  Set<String> _addedFriends = {};
  final List<String> pendingWatchRequests = [];
  final Set<String> _processingWatchAccepts = {};

  // 30-second cooldown for recently handled watch senders
  final Set<String> _recentWatchSenders = {};
  final Map<String, Timer> _recentWatchTimers = {};

  @override
  void initState() {
    super.initState();
    _pendingWatchStreamController = StreamController<List<String>>.broadcast(
      onListen: () => _pendingWatchStreamController.add(List<String>.from(pendingWatchRequests)),
    );
    _watchingBuddiesStreamController = StreamController<Set<String>>.broadcast(
      onListen: () => _watchingBuddiesStreamController.add(Set<String>.from(_watchingBuddies)),
    );

    _loadCurrentIdentityMetrics();
    _loadEnabledFeatures();
    _loadWatchState();
    _checkPermissionsAndStartBLE();
    _refreshContactsTrayList();

    _diagTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      print('📡 [DIAG] BLE scan: ${_totalScanResults} total packets, '
          '${_uniqueHopsDevices.length} unique Hops devices in last 5s');
      _totalScanResults = 0;
      _uniqueHopsDevices.clear();
    });
  }

  @override
  void dispose() {
    _flareCancelTimer?.cancel();
    _bleScanResultsSubscription?.cancel();
    FlutterBluePlus.stopScan();
    BlePeripheral.stopAdvertising();
    _cleanupPairingServer();
    _radarStreamController.close();
    _pendingWatchStreamController.close();
    _watchingBuddiesStreamController.close();
    _gameEventStreamController.close();
    _diagTimer?.cancel();
    _scanRestartTimer?.cancel();
    for (final timer in _recentWatchTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  // ---------- Watch state persistence ----------
  Future<void> _loadWatchState() async {
    final prefs = await SharedPreferences.getInstance();
    final watching = prefs.getStringList('watchingBuddies') ?? [];
    setState(() => _watchingBuddies = watching.toSet());
    _notifyWatchingBuddiesChanged();
  }

  void _cancelEmergencyFlare({bool silent = false}) {
    _flareCancelTimer?.cancel();
    _flareCancelTimer = null;

    BlePeripheral.stopAdvertising();
    BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);

    setState(() => _isFlareActive = false);

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Emergency flare cancelled"),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _sendGameAction(String action, Map<String, String> data) async {
    final advName = "GAME_$action:${data.entries.map((e) => '${e.key}=${e.value}').join(';')}";
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(localName: advName, services: []);
    Future.delayed(const Duration(seconds: 2), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
    });
  }

  Future<void> _broadcastEmergencyFlare(String reason) async {
    _cancelEmergencyFlare(silent: true);

    final maxSenderLen = 8;
    final maxReasonLen = 14;
    final sender = myUsername.length > maxSenderLen
        ? myUsername.substring(0, maxSenderLen)
        : myUsername;
    final shortReason = reason.length > maxReasonLen
        ? reason.substring(0, maxReasonLen)
        : reason;

    final advName = "EMG:$sender:$shortReason";
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(localName: advName, services: []);
    print("🚨 Broadcasting emergency: $advName");

    setState(() => _isFlareActive = true);

    _flareCancelTimer = Timer(const Duration(seconds: 30), () {
      _cancelEmergencyFlare(silent: true);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Emergency flare active for 30 seconds"),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 30),
          action: SnackBarAction(
            label: "CANCEL",
            textColor: Colors.white,
            onPressed: () {
              _cancelEmergencyFlare();
            },
          ),
        ),
      );
    }
  }

  Future<void> _saveWatchState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('watchingBuddies', _watchingBuddies.toList());
  }

  void _notifyWatchRequestsChanged() {
    _pendingWatchStreamController.add(List<String>.from(pendingWatchRequests));
  }

  void _notifyWatchingBuddiesChanged() {
    _watchingBuddiesStreamController.add(Set<String>.from(_watchingBuddies));
  }

  void clearAllWatchState() {
    setState(() {
      _watchingBuddies.clear();
      pendingWatchRequests.clear();
      _recentWatchSenders.clear();
      for (final timer in _recentWatchTimers.values) {
        timer.cancel();
      }
      _recentWatchTimers.clear();
      _saveWatchState();
      _notifyWatchingBuddiesChanged();
      _notifyWatchRequestsChanged();
      _handledWatchAcks.clear();
    });
  }

  // ---------- Friend request logic ----------
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
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
    });
  }

  Future<void> _advertiseVibeTag(String location, int level) async {
    final advName = "VBT:$location:$level";
    if (advName.length > 29) { _showToastFeedbackAlert("Location name too long"); return; }
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(localName: advName, services: []);
    Future.delayed(const Duration(seconds: 30), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
      _startContinuousScan();
    });
  }

  Future<void> acceptFriendRequest(String sender) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(localName: "FRIEND_ACK:$sender:$myUsername", services: []);
    if (!_addedFriends.contains(sender)) {
      _addedFriends.add(sender);
      await _refreshContactsTrayList();
    }
    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
    });
  }

  void acceptRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() => pendingRequests.remove(sender));
    acceptFriendRequest(sender).then((_) => _processingAccepts.remove(sender));
  }

  void declineRequest(String sender) {
    _processingAccepts.add(sender);
    setState(() => pendingRequests.remove(sender));
    Future.delayed(const Duration(seconds: 2), () => _processingAccepts.remove(sender));
  }

  // ---------- Watch request handling ----------
  void acceptWatchRequestFromCard(String sender) {
    _processingWatchAccepts.add(sender);
    setState(() => pendingWatchRequests.remove(sender));
    _notifyWatchRequestsChanged();
    _watchingBuddies.add(sender);
    _saveWatchState();
    _notifyWatchingBuddiesChanged();
    _acceptWatchRequestBle(sender);
    _addRecentWatchSender(sender);
    Future.delayed(const Duration(seconds: 2), () => _processingWatchAccepts.remove(sender));
  }

  void declineWatchRequestFromCard(String sender) {
    _processingWatchAccepts.add(sender);
    setState(() => pendingWatchRequests.remove(sender));
    _notifyWatchRequestsChanged();
    _addRecentWatchSender(sender);
    Future.delayed(const Duration(seconds: 2), () => _processingWatchAccepts.remove(sender));
  }

  void _addRecentWatchSender(String sender) {
    _recentWatchSenders.add(sender);
    _recentWatchTimers[sender]?.cancel();
    _recentWatchTimers[sender] = Timer(const Duration(seconds: 30), () {
      _recentWatchSenders.remove(sender);
      _recentWatchTimers.remove(sender);
    });
  }

  Future<void> _acceptWatchRequestBle(String sender) async {
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(localName: "WATCH_ACK:$sender:$myUsername", services: []);
    Future.delayed(const Duration(seconds: 5), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
    });
  }

  void _onWatchRequestAccepted(String buddy) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("$buddy accepted your watch request")),
    );
  }

  Future<void> sendWatchRequest(String targetUsername) async {
    if (_watchingBuddies.contains(targetUsername)) {
      _showToastFeedbackAlert("Already watching $targetUsername");
      return;
    }
    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: "WATCH_REQ:$targetUsername:$myUsername",
      services: [],
    );
    Future.delayed(const Duration(seconds: 10), () {
      BlePeripheral.stopAdvertising();
      BlePeripheral.startAdvertising(localName: "HPS:$myUsername", services: []);
    });
  }

  void stopWatchingBuddy(String buddy) {
    setState(() {
      _watchingBuddies.remove(buddy);
      _saveWatchState();
      _notifyWatchingBuddiesChanged();
    });
    _addRecentWatchSender(buddy);
  }

  // ---------- Permissions & BLE ----------
  Future<void> _checkPermissionsAndStartBLE() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location, Permission.bluetoothAdvertise,
      Permission.bluetoothConnect, Permission.bluetoothScan,
    ].request();
    bool granted = statuses[Permission.location]!.isGranted &&
        statuses[Permission.bluetoothScan]!.isGranted;
    if (!granted) {
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HopsRootGatekeeper()),
              (route) => false,
        );
      }
      return;
    }
    _initializeParallelBleTransceiverEngine();
  }

  Future<void> _loadCurrentIdentityMetrics() async {
    final prefs = await SharedPreferences.getInstance();
    final avatarPath = prefs.getString('avatar_path');
    setState(() {
      myUsername = prefs.getString('my_username') ?? 'Unknown_User';
      _myAvatarPath = avatarPath;
    });
  }

  Future<void> _startChatConnection(String friendUsername) async {
    // Show a loading indicator while we discover and connect
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final chatService = ChatConnectionService(myUsername: myUsername);
    final endpointId = await chatService.connectToFriend(friendUsername);

    // Close the loading dialog
    if (mounted) Navigator.of(context).pop();

    if (endpointId != null && mounted) {
      // Connection successful → open chat with the live service
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => IndividualChatTerminalView(
            peerName: friendUsername,
            chatService: chatService,
          ),
        ),
      ).then((_) {
        chatService.disconnect();
        _refreshContactsTrayList();
      });
    } else {
      // Connection failed → open chat in offline mode (local only)
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Friend not nearby. Chat will be local.")),
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => IndividualChatTerminalView(
              peerName: friendUsername,
              chatService: null,
            ),
          ),
        ).then((_) => _refreshContactsTrayList());
      }
    }
  }

  void _initializeParallelBleTransceiverEngine() async {
    if (_bleInitialized) return;
    _bleInitialized = true;
    await BlePeripheral.initialize();
    try {
      await BlePeripheral.startAdvertising(
        localName: "HPS:$myUsername",
        services: [],
      );
      print('✅ Advertising started successfully');
    } catch (e) {
      print('❌ Advertising failed: $e');
    }
    _bleScanResultsSubscription = FlutterBluePlus.scanResults.listen((results) async {
      _totalScanResults += results.length;

      for (final r in results) {
        if (r.advertisementData.advName.startsWith("HPS:")) {
          _uniqueHopsDevices.add(r.device.remoteId.toString());
        }
      }

      // Throttle: only forward results every 500ms when in noise mode
      const noiseMode = bool.fromEnvironment('NOISE_MODE', defaultValue: false);
      if (!noiseMode || DateTime.now().difference(_lastRadarPush).inMilliseconds >= 500) {
        _radarStreamController.add(results);
        _lastRadarPush = DateTime.now();
      }

      for (final r in results) {
        final name = r.advertisementData.advName;
        // ACK
        if (name.startsWith("ACK:") && _activePairingCode != null) {
          final parts = name.substring(4).split(":");
          if (parts.length == 2 && parts[0] == _activePairingCode) {
            final user = parts[1];
            if (!localActiveContacts.any((c) => c['username'] == user)) {
              await _writeContactLogToDatabase(user, "Mutual pairing via code");
            }
          }
        }
        // Friend request
        if (name.startsWith("FRIEND_REQ:")) {
          final parts = name.substring(11).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            final sender = parts[1];
            if (!friendUsernames.contains(sender) &&
                !pendingRequests.contains(sender) &&
                !_processingAccepts.contains(sender)) {
              setState(() => pendingRequests.add(sender));
            }
          }
        }
        // Friend ACK
        if (name.startsWith("FRIEND_ACK:")) {
          final parts = name.substring(11).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            // Register the friend without a chat message
            if (!_addedFriends.contains(parts[1])) {
              _addedFriends.add(parts[1]);
              await _refreshContactsTrayList();
            }
          }
        }

        // Watch request
        if (name.startsWith("WATCH_REQ:")) {
          final parts = name.substring(10).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            final sender = parts[1];
            if (!_recentWatchSenders.contains(sender) &&
                !pendingWatchRequests.contains(sender) &&
                !_processingWatchAccepts.contains(sender)) {
              _addRecentWatchSender(sender);
              setState(() => pendingWatchRequests.add(sender));
              _notifyWatchRequestsChanged();
            }
          }
        }

        // Watch ACK – permanent one‑time snackbar
        if (name.startsWith("WATCH_ACK:")) {
          final parts = name.substring(10).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            final sender = parts[1];
            if (!_handledWatchAcks.contains(sender)) {
              _handledWatchAcks.add(sender);
              _onWatchRequestAccepted(sender);
            }
          }
        }

        // Tag game
        if (name.startsWith("TAG:")) {
          final parts = name.substring(4).split(":");
          if (parts.length == 2 && parts[0] == myUsername) {
            final tagger = parts[1];
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                title: const Text("You've been tagged!"),
                content: Text("$tagger tagged you!"),
                actions: [
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text("OK"),
                  ),
                ],
              ),
            );
          }
        }
        // Hops & Robbers game actions
        if (name.startsWith("GAME_")) {
          final parts = name.substring(5).split(":");
          if (parts.length == 2) {
            final action = parts[0];
            final data = <String, String>{};
            for (final pair in parts[1].split(';')) {
              final kv = pair.split('=');
              if (kv.length == 2) data[kv[0]] = kv[1];
            }
            _gameEventStreamController.add({'action': action, 'data': data});
          }
        }
        // Emergency Flare (with reason parsing)
        if (name.startsWith("EMG:")) {
          final payload = name.substring(4);
          final parts = payload.split(':');
          final sender = parts.isNotEmpty ? parts[0] : 'Unknown';
          final reason = parts.length > 1 ? parts.sublist(1).join(':') : 'Emergency';
          await NotificationService.showEmergencyNotification(
            sender: sender,
            reason: reason,
          );
        }
      }
    });
    await _startContinuousScan();
  }

  Future<void> _stopAllAdvertising() async => BlePeripheral.stopAdvertising();
  Future<void> _startContinuousScan() async {
    const noiseMode = bool.fromEnvironment('NOISE_MODE', defaultValue: false);

    if (noiseMode) {
      await FlutterBluePlus.startScan(
        androidUsesFineLocation: true,
        continuousUpdates: true,
        androidScanMode: AndroidScanMode.lowLatency,   // still faster!
      );
    } else {
      await FlutterBluePlus.startScan(
        androidUsesFineLocation: true,
        continuousUpdates: true,
      );
    }
  }

  // ---------- Pairing ----------
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

  // ---------- Contacts management ----------
  Future<void> _refreshContactsTrayList() async {
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(DatabaseHelper.table);
    Map<String, Map<String, dynamic>> contactThreads = {};

    // Existing contacts from messages
    for (var row in maps) {
      String sender = row[DatabaseHelper.columnSenderId] as String;
      if (sender != myUsername) {
        contactThreads[sender] = {
          'username': sender,
          'lastMsg': row[DatabaseHelper.columnMessage] as String,
          'time': 'Nearby'
        };
      }
    }

    // Ensure every added friend appears, even with no messages
    for (final friend in _addedFriends) {
      if (!contactThreads.containsKey(friend)) {
        contactThreads[friend] = {
          'username': friend,
          'lastMsg': 'Connected',
          'time': ''
        };
      }
    }

    setState(() => localActiveContacts = contactThreads.values.toList());
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
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: theme.colorScheme.primary,
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

  // ---------- Feature toggling ----------
  void _toggleFeature(int featureId) {
    setState(() {
      if (enabledFeatureIds.contains(featureId)) {
        enabledFeatureIds.remove(featureId);
      } else {
        enabledFeatureIds.add(featureId);
      }
    });
    _saveEnabledFeatures();
  }

  Future<void> _loadEnabledFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('enabledFeatureIds') ?? [];
    setState(() => enabledFeatureIds = ids.map((s) => int.parse(s)).toSet());
  }

  Future<void> _saveEnabledFeatures() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('enabledFeatureIds', enabledFeatureIds.map((id) => id.toString()).toList());
  }

  // ---------- UI (fully dynamic theme) ----------
  PreferredSizeWidget _buildSharedCustomAppBar(String title) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
      title: Row(
        children: [
          Icon(Icons.bluetooth_audio, color: colors.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 20),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                color: colors.tertiaryContainer.withOpacity(0.2),
                borderRadius: BorderRadius.circular(100)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.radar, size: 10, color: colors.tertiaryContainer),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    "BLE Mesh Active",
                    style: TextStyle(
                        color: colors.tertiaryContainer,
                        fontSize: 9,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const HopsProfileScreen()),
          ).then((_) {
            _refreshContactsTrayList();
            _loadCurrentIdentityMetrics();
          }),
          child: Container(
            margin: const EdgeInsets.only(right: 16),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: colors.primary,
              backgroundImage: _myAvatarPath != null
                  ? FileImage(File(_myAvatarPath!))
                  : null,
              child: _myAvatarPath == null
                  ? const Icon(Icons.person, size: 18, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final List<Widget> tabs = [
      RadarScreen(
        radarStream: radarStream,
        onSendFriendRequest: sendFriendRequest,
        pendingRequests: pendingRequests,
        onAcceptRequest: acceptRequest,
        onDeclineRequest: declineRequest,
        friendUsernames: friendUsernames,
        onActivateFlare: (String reason) => _broadcastEmergencyFlare(reason),
        onRescan: () {                                 // <-- add this
          FlutterBluePlus.stopScan();
          FlutterBluePlus.startScan(
            androidUsesFineLocation: true,
            continuousUpdates: true,
          );
        },
      ),
      _buildContactsTab(),
      _buildFeaturesTab(),
      _buildMyFeaturesTab(),
    ];

    return Scaffold(
      body: tabs[_currentIndex],
      floatingActionButton: _currentIndex == 1
          ? Padding(
        padding: const EdgeInsets.only(bottom: 12.0),
        child: FloatingActionButton(
          backgroundColor: colors.primary,
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          onPressed: () => _showAddContactModalSheet(context),
          child: const Icon(Icons.add, size: 28),
        ),
      )
          : null,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: colors.surface.withOpacity(0.8),
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(0, Icons.radar, Icons.radar, "Radar"),
                _buildNavItem(1, Icons.people_outline, Icons.people, "Contacts"),
                _buildNavItem(2, Icons.grid_view_outlined, Icons.grid_view, "Features"),
                _buildNavItem(3, Icons.star_outline, Icons.star, "My Features"),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, String label) {
    bool isSelected = _currentIndex == index;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return GestureDetector(
      onTap: () => setState(() => _currentIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isSelected ? activeIcon : icon,
                color: isSelected ? Colors.white : colors.primary.withOpacity(0.6)),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? Colors.white : colors.primary.withOpacity(0.6),
                ),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsTab() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: _buildSharedCustomAppBar("Contacts"),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
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
                  backgroundColor: colors.primary.withOpacity(0.1),
                  child: Text(contact['username'] as String, style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
                ),
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        contact['username'] as String,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: colors.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      contact['time'] as String,
                      style: const TextStyle(fontSize: 11, color: Colors.black38),
                    ),
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    contact['lastMsg'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.chat_bubble_outline, color: colors.primary),
                      onPressed: () => _startChatConnection(contact['username'] as String),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                      onPressed: () => _deleteContactFromTrayIndex(contact['username'] as String),
                    ),
                  ],
                ),
                onTap: null,  // Remove the old onTap that opened the chat directly
              ),
            );
          },
        ),
      ),
    );
  }

  void _showAddContactModalSheet(BuildContext context) {
    final theme = Theme.of(context);      // ← here
    final colors = theme.colorScheme;     // ← here
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
                Text("Add Peer Node", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colors.primary)),
                const SizedBox(height: 6),
                const Text("Enter the 6‑character pairing code shown on your classmate's device.", style: TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 24),
                Text("ENTER PAIRING CODE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: colors.primary, letterSpacing: 1.2)),
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
                    fillColor: colors.surfaceContainerHighest,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: colors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100))),
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
                Divider(color: colors.surfaceContainerHighest),
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    icon: Icon(Icons.qr_code_scanner, size: 18, color: colors.tertiaryContainer),
                    label: Text("Generate My Pairing Code", style: TextStyle(color: colors.tertiaryContainer, fontWeight: FontWeight.bold, fontSize: 13)),
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
    final theme = Theme.of(context);      // ← here
    final colors = theme.colorScheme;     // ← here
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
            decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(16)),
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
              child: Row(
                children: [
                  Icon(Icons.camera_alt_outlined, color: colors.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Scan to Add", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const Text("Open camera viewfinder to decode transient QR matrix map signatures.", style: TextStyle(fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 16, color: Colors.black26),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  void _showTokenGeneratorDialog(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: colors.surfaceContainerHighest.withOpacity(0.4),
      elevation: 0,
      child: ExpansionTile(
        leading: Icon(feature.icon, color: colors.primary, size: 28),
        title: Text(
          feature.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
            color: colors.primary,   // ★ use the theme primary colour
          ),
        ),
        subtitle: Text(
          feature.shortDesc,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.black54),
          maxLines: 1,
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
                      ? colors.tertiaryContainer.withOpacity(0.3)
                      : colors.primary,
                  foregroundColor: isEnabled ? colors.primary : Colors.white,
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

  // --------------- My Features tab ---------------
  Widget _buildMyFeaturesTab() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabledFeatures = allFeatures
        .where((f) => enabledFeatureIds.contains(f.id))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text("My Features",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor.withOpacity(0.8),
        actions: [
          TextButton.icon(
            icon: Icon(Icons.add_circle_outline, size: 18, color: colors.primary),
            label: Text("Manage", style: TextStyle(color: colors.primary)),
            onPressed: () => setState(() => _currentIndex = 2),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.0, -1.0),
            radius: 1.5,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: enabledFeatures.isEmpty
            ? const Center(
          child: Text(
            "No features added yet.\nGo to 'Features' to enable some!",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        )
            : GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 0.9,
          ),
          itemCount: enabledFeatures.length,
          itemBuilder: (context, index) {
            final feature = enabledFeatures[index];
            return GestureDetector(
              onTap: () {
                if (feature.id == 2) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WatchMePage(
                        radarStream: radarStream,
                        friendUsernames: friendUsernames,
                        watchingBuddies: _watchingBuddies,
                        watchingBuddiesStream: watchingBuddiesStream,
                        pendingWatchStream: pendingWatchStream,
                        onSendWatchRequest: sendWatchRequest,
                        onAcceptWatchRequest: acceptWatchRequestFromCard,
                        onDeclineWatchRequest: declineWatchRequestFromCard,
                        onStopWatching: stopWatchingBuddy,
                        onClearAll: clearAllWatchState,
                      ),
                    ),
                  );
                } else if (feature.id == 5) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VibeCheckPage(
                        radarStream: radarStream,
                        onAdvertiseVibeTag: _advertiseVibeTag,
                      ),
                    ),
                  );
                } else if (feature.id == 8) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => HopsAndRobbersPage(
                        radarStream: radarStream,
                        myUsername: myUsername,
                        onSendGameAction: _sendGameAction,
                        gameEventStream: gameEventStream,
                      ),
                    ),
                  );
                } else if (feature.id == 9) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const TaskTrackerPage(),
                    ),
                  );
                } else if (feature.id == 11) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => HopsSharePage(
                        myUsername: myUsername,
                      ),
                    ),
                  );
                } else if (feature.pageBuilder != null) {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => feature.pageBuilder!()),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("${feature.name} page not built yet")),
                  );
                }
              },
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                color: Colors.white.withOpacity(0.6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(feature.icon, size: 36, color: colors.primary),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        feature.name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: colors.primary,
                        ),
                        maxLines: 2,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}