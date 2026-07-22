import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:client/theme/hops_theme.dart';

class ReceivedFilesPage extends StatefulWidget {
  const ReceivedFilesPage({super.key});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  List<Map<String, dynamic>> _records = [];

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
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not open file: ${result.message}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    return Scaffold(
      appBar: AppBar(
        title: Flexible(
          child: Text(
            "Received Files",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
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
          final size = rec['size'] ?? 0;
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
                backgroundColor: colors.primary.withOpacity(0.1),
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
              trailing: IconButton(
                icon: const Icon(Icons.open_in_new),
                onPressed: () => _openFile(fileName.toString()),
              ),
            ),
          );
        },
      ),
    );
  }
}