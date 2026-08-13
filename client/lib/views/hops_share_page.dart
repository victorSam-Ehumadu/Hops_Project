import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:client/views/received_files_page.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/main.dart' show nearbyConnectionsSessionCount;

class HopsSharePage extends StatefulWidget {
  final String myUsername;
  const HopsSharePage({super.key, required this.myUsername});
  @override
  State<HopsSharePage> createState() => _HopsSharePageState();
}

class _HopsSharePageState extends State<HopsSharePage> {
  List<NearbyDevice> _discoveredDevices = [];
  String? _connectedEndpointId;
  bool _isConnected = false;
  PlatformFile? _pickedFile;
  bool _isSending = false;
  // 0.0–1.0 while a send is in flight, null otherwise — fed by
  // Nearby Connections' own onPayloadTransferUpdate, not a fake/simulated
  // timer, so it reflects real bytes-on-the-wire progress.
  double? _sendProgress;
  bool _hasPermissions = false;
  bool _checkingPermissions = true;

  final TextEditingController _textNoteController = TextEditingController();

  // Service ID must be passed explicitly — the package default is unrelated.
  static const String _serviceId = "com.hops.share";

  @override
  void initState() {
    super.initState();
    // Stop BLE advertising while Nearby Connections is active — both compete
    // for Bluetooth Classic resources.
    BlePeripheral.stopAdvertising();
    // Tells HopsApp (which is still alive underneath this pushed screen) to
    // pause its own background BLE advertising-refresh/scan-cycle timers
    // for as long as this session is open — see hops_app.dart's
    // _pauseBackgroundBleForNearbyConnections for why those otherwise keep
    // firing regardless of what's on top of it.
    nearbyConnectionsSessionCount.value++;
    _requestPermissionsAndStart();
  }

  @override
  void dispose() {
    _cleanupNearby();
    // Restore Hops BLE advertising WITH the service UUID so the radar
    // hardware filter picks us up again immediately.
    BlePeripheral.startAdvertising(
      localName: "HPS:${widget.myUsername}",
      services: [HOPS_SERVICE_UUID],
    );
    nearbyConnectionsSessionCount.value--;
    _textNoteController.dispose();
    super.dispose();
  }

  // ── Permissions ────────────────────────────────────────────────────────────
  // Nearby Connections on Android 13+ requires NEARBY_WIFI_DEVICES in addition
  // to the Bluetooth permissions. Without it, discovery silently finds nothing.
  Future<void> _requestPermissionsAndStart() async {
    final statuses = await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,   // ← the missing permission
    ].request();

    final granted = statuses.values.every(
          (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );

    setState(() {
      _hasPermissions = granted;
      _checkingPermissions = false;
    });

    if (granted) {
      _startNearbyDiscoveryAndAdvertising();
    }
  }

  // ── Nearby Connections ─────────────────────────────────────────────────────
  void _startNearbyDiscoveryAndAdvertising() {
    // Both advertise AND discover simultaneously — P2P_CLUSTER supports this.
    Nearby().startAdvertising(
      widget.myUsername,
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,           // ← was missing; used the package default before
      onConnectionInitiated: (id, info) {
        Nearby().acceptConnection(
          id,
          onPayLoadRecieved: (endpointId, payload) =>
              _onPayloadReceived(endpointId, payload),
          onPayloadTransferUpdate: _onTransferUpdate,
        );
        setState(() {
          _connectedEndpointId = id;
          _isConnected = true;
        });
      },
      onConnectionResult: (id, status) {
        setState(() {
          if (status == Status.CONNECTED) {
            _connectedEndpointId = id;
            _isConnected = true;
          } else {
            _connectedEndpointId = null;
            _isConnected = false;
          }
        });
      },
      onDisconnected: (id) {
        setState(() {
          _connectedEndpointId = null;
          _isConnected = false;
        });
      },
    );

    Nearby().startDiscovery(
      widget.myUsername,
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,           // ← was missing
      onEndpointFound: (id, name, serviceId) {
        setState(() {
          _discoveredDevices.removeWhere((d) => d.id == id);
          _discoveredDevices.add(NearbyDevice(id: id, name: name));
        });
      },
      onEndpointLost: (id) {
        setState(() => _discoveredDevices.removeWhere((d) => d.id == id));
      },
    );
  }

  void _cleanupNearby() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
  }

  void _connectToDevice(String endpointId) {
    Nearby().requestConnection(
      widget.myUsername,
      endpointId,
      onConnectionInitiated: (id, info) {
        Nearby().acceptConnection(
          id,
          onPayLoadRecieved: (endpointId, payload) =>
              _onPayloadReceived(endpointId, payload),
          onPayloadTransferUpdate: _onTransferUpdate,
        );
      },
      onConnectionResult: (id, status) {
        setState(() {
          if (status == Status.CONNECTED) {
            _connectedEndpointId = id;
            _isConnected = true;
          }
        });
      },
      onDisconnected: (id) {
        setState(() {
          _connectedEndpointId = null;
          _isConnected = false;
        });
      },
    );
  }

  // ── Payload handling ───────────────────────────────────────────────────────
  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type != PayloadType.BYTES) return;
    final data = payload.bytes!;
    final firstNull = data.indexOf(0);
    if (firstNull == -1) return;
    final sender = utf8.decode(data.sublist(0, firstNull));
    final secondNull = data.indexOf(0, firstNull + 1);
    if (secondNull == -1) return;
    final fileName = utf8.decode(data.sublist(firstNull + 1, secondNull));
    final fileData = data.sublist(secondNull + 1);
    _saveReceivedFile(sender, fileName, fileData);
  }

  Future<void> _saveReceivedFile(
      String sender, String fileName, Uint8List data) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(data, flush: true);
    await _updateReceivedFilesRecord(sender, fileName, data.length);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              "Received $fileName from $sender (${data.length} bytes)"),
        ),
      );
    }
    // Files can land here well after the sender's transfer finished — a
    // system notification is what actually tells you it arrived if you've
    // since backgrounded the app or moved to a different screen.
    await NotificationService.showFileReceivedNotification(sender: sender, fileName: fileName);
  }

  Future<void> _updateReceivedFilesRecord(
      String sender, String fileName, int size) async {
    final dir = await getApplicationDocumentsDirectory();
    final recordFile = File('${dir.path}/received_files.json');
    List<Map<String, dynamic>> records = [];
    if (await recordFile.exists()) {
      final content = await recordFile.readAsString();
      if (content.isNotEmpty) {
        records = List<Map<String, dynamic>>.from(json.decode(content));
      }
    }
    records.add({
      'sender': sender,
      'fileName': fileName,
      'size': size,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    await recordFile.writeAsString(json.encode(records), flush: true);
  }

  // ── File picking & sending ─────────────────────────────────────────────────
  void _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => _pickedFile = result.files.first);
    }
  }

  Future<void> _sendPickedFile() async {
    if (_pickedFile == null || _connectedEndpointId == null) return;
    setState(() {
      _isSending = true;
      _sendProgress = 0;
    });
    try {
      final payload = Uint8List.fromList([
        ...utf8.encode(widget.myUsername), 0,
        ...utf8.encode(_pickedFile!.name), 0,
        ..._pickedFile!.bytes!,
      ]);
      // sendBytesPayload only confirms the OS accepted the send request —
      // it resolves almost instantly regardless of file size, well before
      // the transfer itself finishes. The actual progress (and eventual
      // completion) arrives later via onPayloadTransferUpdate, so
      // _isSending/_pickedFile are deliberately NOT reset here; resetting
      // them right after this await used to make the progress bar vanish
      // almost immediately no matter how big the file was.
      await Nearby().sendBytesPayload(_connectedEndpointId!, payload);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Transfer failed: $e")),
        );
        setState(() {
          _isSending = false;
          _sendProgress = null;
        });
      }
    }
  }

  // Nearby Connections reports progress for every payload crossing this
  // connection, incoming or outgoing — there's no direction flag on the
  // update itself. Gating on _isSending is safe here because this screen
  // only ever has one transfer in flight at a time (the UI disables
  // picking/sending while one's active), so any update that arrives while
  // we're sending can only be about the file we just started sending.
  void _onTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (!_isSending) return;
    if (!mounted) return;
    if (update.status == PayloadStatus.IN_PROGRESS && update.totalBytes > 0) {
      setState(() => _sendProgress = update.bytesTransferred / update.totalBytes);
    } else if (update.status == PayloadStatus.SUCCESS) {
      setState(() {
        _isSending = false;
        _sendProgress = null;
        _pickedFile = null;
      });
    } else if (update.status == PayloadStatus.FAILURE ||
        update.status == PayloadStatus.CANCELED) {
      setState(() {
        _isSending = false;
        _sendProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Transfer failed — try again.")),
      );
    }
  }

  void _sendTextNote() {
    if (_connectedEndpointId == null) return;
    final text = _textNoteController.text.trim();
    if (text.isEmpty) return;
    final payload = Uint8List.fromList([
      ...utf8.encode(widget.myUsername), 0,
      ...utf8.encode("note.txt"), 0,
      ...utf8.encode(text),
    ]);
    Nearby().sendBytesPayload(_connectedEndpointId!, payload);
    _textNoteController.clear();
    setState(() {});
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Hops Share",
          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          TextButton.icon(
            icon: Icon(Icons.folder_open, color: colors.primary, size: 20),
            label: Text(
              "Received Files",
              style: TextStyle(color: colors.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReceivedFilesPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _checkingPermissions
          ? const Center(child: CircularProgressIndicator())
          : !_hasPermissions
          ? _buildPermissionDeniedView(colors)
          : _isConnected
          ? _buildConnectedView()
          : _buildDiscoveryView(),
    );
  }

  Widget _buildPermissionDeniedView(ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 48, color: colors.primary.withOpacity(0.4)),
            const SizedBox(height: 16),
            const Text(
              "Permissions required",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              "Hops Share needs Nearby Devices, Location, and Bluetooth "
                  "permissions to find nearby peers. Please grant them in "
                  "Settings → Apps → Hops → Permissions.",
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurface.withOpacity(0.6), fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () {
                setState(() => _checkingPermissions = true);
                _requestPermissionsAndStart();
              },
              icon: const Icon(Icons.refresh),
              label: const Text("Try Again"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryView() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            "Nearby Devices",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: _discoveredDevices.isEmpty
              ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  "Searching for nearby Hops users…",
                  style: TextStyle(color: colors.onSurface.withOpacity(0.5)),
                ),
              ],
            ),
          )
              : ListView.builder(
            itemCount: _discoveredDevices.length,
            itemBuilder: (context, index) {
              final device = _discoveredDevices[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: colors.primary.withOpacity(0.1),
                  child: Text(
                    device.name.isNotEmpty ? device.name[0] : '?',
                    style: TextStyle(color: colors.primary),
                  ),
                ),
                title: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: ElevatedButton(
                  onPressed: () => _connectToDevice(device.id),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Connect"),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedView() {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.circle, size: 10, color: Colors.green),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  "Connected to ${_connectedEndpointId ?? ''}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.file_present),
            label: const Text("Choose a File"),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: Colors.white,
              padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
            onPressed: _pickFile,
          ),
          if (_pickedFile != null) ...[
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file,
                        size: 36, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _pickedFile!.name,
                            style:
                            const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            "${(_pickedFile!.size / 1024).toStringAsFixed(1)} kB",
                          ),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isSending ? null : _sendPickedFile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.primary,
                        foregroundColor: Colors.white,
                      ),
                      child: _isSending
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                          : const Text("Send"),
                    ),
                  ],
                ),
              ),
            ),
            if (_isSending) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(100),
                child: LinearProgressIndicator(
                  // null progress (still 0 or first update hasn't landed
                  // yet) falls back to an indeterminate bar rather than
                  // sitting frozen at a misleading 0%.
                  value: (_sendProgress != null && _sendProgress! > 0) ? _sendProgress : null,
                  minHeight: 6,
                  backgroundColor: colors.primary.withOpacity(0.12),
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _sendProgress != null
                    ? "${(_sendProgress! * 100).toStringAsFixed(0)}% sent"
                    : "Starting transfer…",
                style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.5)),
              ),
            ],
          ],
          const SizedBox(height: 24),
          const Divider(),
          const Text(
            "Or send a quick text note:",
            style: TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textNoteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: "Type your note...",
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _textNoteController.text.isNotEmpty
                    ? _sendTextNote
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
                ),
                child: const Text("Send"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class NearbyDevice {
  final String id;
  final String name;
  NearbyDevice({required this.id, required this.name});
}