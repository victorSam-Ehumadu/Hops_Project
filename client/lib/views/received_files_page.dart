import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  List<Map<String, dynamic>> _records = [];
  // Tracks which file (by name) has a save in progress, so its download
  // button can show a spinner and every OTHER row's button stays tappable
  // — a shared "busy" bool would freeze the whole list over one save.
  String? _savingFileName;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final dir = await getApplicationDocumentsDirectory();
    final recordFile = File('${dir.path}/received_files.json');
    if (await recordFile.exists()) {
      final content = await recordFile.readAsString();
      if (content.isNotEmpty) {
        setState(() {
          _records = List<Map<String, dynamic>>.from(json.decode(content));
        });
      }
    }
  }

  void _openFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$fileName';
    final result = await OpenFilex.open(path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not open file: ${result.message}")),
      );
    }
  }

  // Saves a copy of a received file to wherever the user picks — the
  // file_picker save dialog (Storage Access Framework on Android) opens
  // to Downloads by default on every device this has been checked against,
  // so "tap Download, tap Save" lands the file there without the user
  // needing to navigate anywhere, while still letting them choose a
  // different folder if they want one. This is deliberately NOT the same
  // thing as "Share / Save" in the menu below — that hands the file to
  // whatever OTHER APP the user picks (Drive, WhatsApp, etc.); this copies
  // it straight onto the device's own storage, no other app involved.
  Future<void> _downloadFile(String fileName) async {
    setState(() => _savingFileName = fileName);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sourceFile = File('${dir.path}/$fileName');
      if (!await sourceFile.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("File not found")),
        );
        return;
      }
      final bytes = await sourceFile.readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: fileName,
        bytes: bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(savedPath != null ? "Saved $fileName" : "Save cancelled"),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save $fileName: $e")),
      );
    } finally {
      if (mounted) setState(() => _savingFileName = null);
    }
  }

  void _shareFile(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$fileName';
    final file = File(path);
    if (await file.exists()) {
      await Share.shareXFiles([XFile(path)], text: 'Received via Hops');
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("File not found")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Received Files",
          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: _records.isEmpty
          ? const Center(
        child: Text(
          "No files received yet.",
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _records.length,
        itemBuilder: (context, index) {
          final rec = _records[index];
          final sender = rec['sender'] ?? 'Unknown';
          final fileName = rec['fileName'] ?? 'unknown';
          final ts = rec['timestamp'] ?? 0;
          final date = DateTime.fromMillisecondsSinceEpoch(ts as int);
          final icon = fileName.toString().endsWith('.pdf')
              ? Icons.picture_as_pdf
              : fileName.toString().endsWith('.txt')
              ? Icons.text_snippet
              : Icons.insert_drive_file;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primary.withValues(alpha: 0.1),
                child: Icon(icon, color: colors.primary),
              ),
              title: Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                "From: $sender · ${date.toString().substring(0, 19)}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _savingFileName == fileName
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: Icon(Icons.download_outlined, color: colors.primary),
                          tooltip: 'Download to device',
                          onPressed: () => _downloadFile(fileName.toString()),
                        ),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'open') {
                        _openFile(fileName.toString());
                      } else if (value == 'share') {
                        _shareFile(fileName.toString());
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'open', child: Text('Open')),
                      PopupMenuItem(value: 'share', child: Text('Share…')),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}