import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:client/views/received_files_page.dart';
import 'package:path_provider/path_provider.dart';

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
  final TextEditingController _textNoteController = TextEditingController();
  static const String _serviceId = "com.hops.share";

  @override
  void initState() {
    super.initState();
    BlePeripheral.stopAdvertising();
    _startNearbyDiscoveryAndAdvertising();
  }

  @override
  void dispose() {
    _cleanupNearby();
    BlePeripheral.startAdvertising(
      localName: "HPS:${widget.myUsername}",
      services: [],
    );
    _textNoteController.dispose();
    super.dispose();
  }

  void _startNearbyDiscoveryAndAdvertising() {
    Nearby().startAdvertising(
      widget.myUsername,
      Strategy.P2P_STAR,
      onConnectionInitiated: (id, info) {
        Nearby().acceptConnection(id, onPayLoadRecieved: (endpointId, payload) {
          _onPayloadReceived(endpointId, payload);
        });
        setState(() {
          _connectedEndpointId = id;
          _isConnected = true;
        });
      },
      onConnectionResult: (id, status) {
        if (status == Status.CONNECTED) {
          setState(() {
            _connectedEndpointId = id;
            _isConnected = true;
          });
        } else {
          setState(() {
            _connectedEndpointId = null;
            _isConnected = false;
          });
        }
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
      Strategy.P2P_STAR,
      onEndpointFound: (id, name, serviceId) {
        setState(() {
          _discoveredDevices.removeWhere((d) => d.id == id);
          _discoveredDevices.add(NearbyDevice(id: id, name: name));
        });
      },
      onEndpointLost: (id) {
        setState(() {
          _discoveredDevices.removeWhere((d) => d.id == id);
        });
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
        Nearby().acceptConnection(id, onPayLoadRecieved: (endpointId, payload) {
          _onPayloadReceived(endpointId, payload);
        });
      },
      onConnectionResult: (id, status) {
        if (status == Status.CONNECTED) {
          setState(() {
            _connectedEndpointId = id;
            _isConnected = true;
          });
        }
      },
      onDisconnected: (id) {
        setState(() {
          _connectedEndpointId = null;
          _isConnected = false;
        });
      },
    );
  }

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

  Future<void> _saveReceivedFile(String sender, String fileName, Uint8List data) async {
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$fileName';
    final file = File(filePath);
    await file.writeAsBytes(data);
    _updateReceivedFilesRecord(sender, fileName, data.length);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Received $fileName from $sender (${data.length} bytes)")),
    );
  }

  Future<void> _updateReceivedFilesRecord(String sender, String fileName, int size) async {
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
    await recordFile.writeAsString(json.encode(records));
  }

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
    setState(() => _isSending = true);
    try {
      final payload = Uint8List.fromList([
        ...utf8.encode(widget.myUsername), 0,
        ...utf8.encode(_pickedFile!.name), 0,
        ..._pickedFile!.bytes!,
      ]);
      await Nearby().sendBytesPayload(_connectedEndpointId!, payload);
      print("📤 File sent via Nearby");
    } catch (e) {
      print("❌ Send error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Transfer failed: $e")),
      );
    } finally {
      setState(() {
        _isSending = false;
        _pickedFile = null;
      });
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Hops Share",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: "Received Files",
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReceivedFilesPage()),
            ),
          ),
        ],
      ),
      body: _isConnected ? _buildConnectedView() : _buildDiscoveryView(),
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: _discoveredDevices.isEmpty
              ? const Center(
            child: Text(
              "Searching for devices...",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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
          Text(
            "Connected to ${_connectedEndpointId ?? ''}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.file_present),
            label: const Text("Choose a File"),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            ),
            onPressed: _pickFile,
          ),
          if (_pickedFile != null) ...[
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.insert_drive_file, size: 36, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _pickedFile!.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            "${(_pickedFile!.size / 1024).toStringAsFixed(1)} kB",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                          ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text("Send"),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const Text(
            "Or send a quick text note:",
            style: TextStyle(fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
                onPressed: _textNoteController.text.isNotEmpty ? _sendTextNote : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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