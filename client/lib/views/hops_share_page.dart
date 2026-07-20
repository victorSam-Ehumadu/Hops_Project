import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:uuid/uuid.dart';
import 'package:client/theme/hops_theme.dart';
import 'package:client/views/received_files_page.dart';

class HopsSharePage extends StatefulWidget {
  final Set<String> friendUsernames;
  final String myUsername;

  const HopsSharePage({
    super.key,
    required this.friendUsernames,
    required this.myUsername,
  });

  @override
  State<HopsSharePage> createState() => _HopsSharePageState();
}

class _HopsSharePageState extends State<HopsSharePage> {
  String? _selectedFriend;
  final TextEditingController _textNoteController = TextEditingController();
  PlatformFile? _pickedFile;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    // Stop normal advertising so we can listen for file transfers
    BlePeripheral.stopAdvertising();
    print("🔇 Stopped advertising for file reception");
  }

  @override
  void dispose() {
    // Restart normal advertising when leaving this page
    BlePeripheral.startAdvertising(
      localName: "HPS:${widget.myUsername}",
      services: [],
    );
    print("📢 Restarted advertising");
    _textNoteController.dispose();
    super.dispose();
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
    if (_pickedFile == null || _selectedFriend == null) return;

    setState(() => _isSending = true);
    try {
      await _sendFile(_pickedFile!.name, _pickedFile!.bytes!);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
    setState(() => _pickedFile = null);
  }

  void _sendTextNote() {
    final text = _textNoteController.text.trim();
    if (text.isEmpty || _selectedFriend == null) return;
    _sendFile("note.txt", Uint8List.fromList(utf8.encode(text)));
    _textNoteController.clear();
  }

  Future<void> _sendFile(String fileName, Uint8List data) async {
    if (_selectedFriend == null) return;

    const int chunkSize = 512;
    final int totalChunks = (data.length / chunkSize).ceil();

    // Header: sender\0fileName\0totalChunks
    final header = Uint8List.fromList([
      ...utf8.encode(widget.myUsername),
      0,
      ...utf8.encode(fileName),
      0,
      ...totalChunks.toString().padLeft(6, '0').codeUnits,
    ]);

    final sessionId = const Uuid().v4().substring(0, 8);
    final serviceUuid = Guid("0000${sessionId}-0000-1000-8000-00805f9b34fb");
    final charUuid   = Guid("0000${sessionId}-0000-1000-8000-00805f9b34fc");

    // Create GATT service with initial header value
    await BlePeripheral.addService(BleService(
      uuid: serviceUuid.toString(),
      primary: true,
      characteristics: [
        BleCharacteristic(
          uuid: charUuid.toString(),
          properties: [0x02],   // read
          permissions: [1],     // readable
          value: header,
        ),
      ],
    ));

    await BlePeripheral.stopAdvertising();
    await BlePeripheral.startAdvertising(
      localName: "SHARE",
      services: [serviceUuid.toString()],
    );
    print("📤 Sharing $fileName (${data.length} bytes, $totalChunks chunks)");

    // Wait for receiver to connect
    await Future.delayed(const Duration(seconds: 2));

    // Send chunks using positional updateCharacteristic(charUuid, data)
    final String charUuidStr = charUuid.toString();
    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize > data.length) ? data.length : start + chunkSize;
      final chunk = Uint8List.fromList([
        ...i.toString().padLeft(6, '0').codeUnits,
        0,
        ...data.sublist(start, end),
      ]);

      await BlePeripheral.updateCharacteristic(charUuidStr, chunk);   // ✅ positional
      print("📤 Sent chunk $i / $totalChunks");
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await Future.delayed(const Duration(milliseconds: 200));
    await BlePeripheral.clearServices();
    await BlePeripheral.stopAdvertising();
    print("📤 Transfer complete");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Hops Share", style: TextStyle(fontWeight: FontWeight.bold, color: HopsTheme.primary)),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ---- Friend selector ----
            DropdownButton<String>(
              value: _selectedFriend,
              isExpanded: true,
              hint: const Text("Select a friend"),
              items: widget.friendUsernames
                  .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedFriend = v),
            ),
            const SizedBox(height: 24),

            // ---- File picker ----
            ElevatedButton.icon(
              icon: const Icon(Icons.file_present),
              label: const Text("Choose a File (PDF / Image / etc.)"),
              style: ElevatedButton.styleFrom(
                backgroundColor: HopsTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              ),
              onPressed: _selectedFriend != null ? _pickFile : null,
            ),

            // ---- File preview ----
            if (_pickedFile != null) ...[
              const SizedBox(height: 16),
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.insert_drive_file, size: 36, color: HopsTheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_pickedFile!.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text("${(_pickedFile!.size / 1024).toStringAsFixed(1)} kB",
                                style: const TextStyle(color: Colors.black54)),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: _isSending ? null : _sendPickedFile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: HopsTheme.primary,
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

            // ---- Text note ----
            const Text("Or send a quick text note:", style: TextStyle(fontSize: 14)),
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
                  onPressed: (_selectedFriend != null && _textNoteController.text.isNotEmpty)
                      ? _sendTextNote
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: HopsTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  ),
                  child: const Text("Send"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}