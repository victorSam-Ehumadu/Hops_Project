// vibe_history_page.dart
//
// Your own past Vibe Check submissions — used to live inline on the main
// Vibe Check page underneath Community Reports, which pushed the actually-
// useful "what's crowded right now nearby" list further down the screen
// every time you'd saved a few tags. Split out behind its own labeled
// button (mirrors Hops Share's "Received Files" button) so the main page
// stays focused on reporting/reading live crowd levels.
import 'package:flutter/material.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/widgets/hops_card.dart';

const List<String> _levelNames = ["Quiet", "Moderate", "Busy", "Packed"];
const List<Color> _levelColors = [Colors.green, Colors.amber, Colors.orange, Colors.red];
const List<IconData> _levelIcons = [
  Icons.sentiment_satisfied,
  Icons.sentiment_neutral,
  Icons.sentiment_dissatisfied,
  Icons.sentiment_very_dissatisfied,
];

class VibeHistoryPage extends StatefulWidget {
  const VibeHistoryPage({super.key});

  @override
  State<VibeHistoryPage> createState() => _VibeHistoryPageState();
}

class _VibeHistoryPageState extends State<VibeHistoryPage> {
  List<Map<String, dynamic>> _records = [];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final records = await DatabaseHelper.instance.getVibeRecords();
    if (mounted) setState(() => _records = records);
  }

  Future<void> _deleteRecord(String id) async {
    await DatabaseHelper.instance.deleteVibeRecord(id);
    await _loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "Your Saved History",
          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: _records.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history, size: 40, color: colors.primary.withOpacity(0.25)),
                    const SizedBox(height: 12),
                    Text(
                      "No saved reports yet",
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _records.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final record = _records[index];
                final loc = record[DatabaseHelper.vibeColLocation];
                final count = record[DatabaseHelper.vibeColDeviceCount] as int;
                final ts = record[DatabaseHelper.vibeColTimestamp] as int;
                final date = DateTime.fromMillisecondsSinceEpoch(ts);
                final id = record[DatabaseHelper.vibeColId] as String;
                final level = count <= 2 ? 0 : count <= 5 ? 1 : count <= 10 ? 2 : 3;
                return HopsCard(
                  radius: 16,
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: _levelColors[level],
                        child: Icon(_levelIcons[level], color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(loc.toString(),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            Text(
                              "${_levelNames[level]} · ${date.hour}:${date.minute.toString().padLeft(2, '0')}",
                              style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.5)),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: () => _deleteRecord(id),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
