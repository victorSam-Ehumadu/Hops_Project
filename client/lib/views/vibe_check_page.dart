import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';

class VibeCheckPage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Future<void> Function(String location, int count) onAdvertiseVibeTag;

  const VibeCheckPage({
    super.key,
    required this.radarStream,
    required this.onAdvertiseVibeTag,
  });

  @override
  State<VibeCheckPage> createState() => _VibeCheckPageState();
}

class _VibeCheckPageState extends State<VibeCheckPage> {
  StreamSubscription? _streamSub;

  int _selectedCrowdLevel = 0;

  final TextEditingController _locationController = TextEditingController();
  final FocusNode _focusNode = FocusNode();     // explicit focus for the text field

  List<Map<String, dynamic>> _records = [];

  final Map<String, _CommunityReport> _communityReports = {};

  // Throttle helpers
  DateTime _lastRebuild = DateTime(2000);
  bool _pendingRebuild = false;

  @override
  void initState() {
    super.initState();

    _streamSub = widget.radarStream.listen((results) {
      bool updated = false;

      for (final r in results) {
        final advName = r.advertisementData.advName;
        if (advName.startsWith("VBT:")) {
          final parts = advName.substring(4).split(":");
          if (parts.length == 2) {
            final location = parts[0];
            final levelStr = parts[1];
            final level = int.tryParse(levelStr);
            if (level != null && level >= 0 && level <= 3) {
              _communityReports[advName] = _CommunityReport(
                location: location,
                count: _levelToApproxCount(level),
                level: level,
                timestamp: DateTime.now(),
              );
              updated = true;
            }
          }
        }
      }

      // Remove reports older than 2 minutes
      final now = DateTime.now();
      _communityReports.removeWhere(
              (key, report) => now.difference(report.timestamp).inMinutes > 2);

      if (updated) {
        // Throttle: only schedule a rebuild if at least 2 seconds have passed
        if (now.difference(_lastRebuild).inSeconds >= 2) {
          if (mounted) setState(() {});
          _lastRebuild = now;
          _pendingRebuild = false;
        } else if (!_pendingRebuild) {
          _pendingRebuild = true;
          // Wait until 2 seconds have elapsed, then rebuild once
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _pendingRebuild) {
              setState(() {});
              _lastRebuild = DateTime.now();
              _pendingRebuild = false;
            }
          });
        }
      }
    });

    _loadRecords();
  }

  int _levelToApproxCount(int level) {
    switch (level) {
      case 0: return 1;
      case 1: return 4;
      case 2: return 8;
      case 3: return 15;
      default: return 0;
    }
  }

  Future<void> _loadRecords() async {
    final records = await DatabaseHelper.instance.getVibeRecords();
    setState(() {
      _records = records;
    });
  }

  Future<void> _saveLocation() async {
    final location = _locationController.text.trim();
    if (location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Enter a location name")),
      );
      return;
    }

    final level = _selectedCrowdLevel;
    final approxCount = _levelToApproxCount(level);

    final record = {
      DatabaseHelper.vibeColId: const Uuid().v4(),
      DatabaseHelper.vibeColLocation: location,
      DatabaseHelper.vibeColDeviceCount: approxCount,
      DatabaseHelper.vibeColTimestamp: DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertVibeRecord(record);

    await widget.onAdvertiseVibeTag(location, level);

    _locationController.clear();
    _focusNode.unfocus();   // dismiss the keyboard after saving
    await _loadRecords();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Saved $location as ${_levelNames[level]}")),
      );
    }
  }

  Future<void> _deleteRecord(String id) async {
    await DatabaseHelper.instance.deleteVibeRecord(id);
    await _loadRecords();
  }

  static const List<String> _levelNames = [
    "Quiet",
    "Moderate",
    "Busy",
    "Packed",
  ];

  static const List<Color> _levelColors = [
    Colors.green,
    Colors.amber,
    Colors.orange,
    Colors.red,
  ];

  static const List<IconData> _levelIcons = [
    Icons.sentiment_satisfied,
    Icons.sentiment_neutral,
    Icons.sentiment_dissatisfied,
    Icons.sentiment_very_dissatisfied,
  ];

  @override
  void dispose() {
    _streamSub?.cancel();
    _locationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final communityList = _communityReports.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Flexible(
          child: Text(
            "Vibe Check",
            style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "How crowded is your spot?",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colors.primary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Row(
              children: List.generate(4, (i) {
                final isSelected = _selectedCrowdLevel == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedCrowdLevel = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? _levelColors[i].withOpacity(0.2)
                            : Colors.white.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected ? _levelColors[i] : Colors.grey.shade300,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Icon(_levelIcons[i], color: _levelColors[i], size: 28),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _levelNames[i],
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: isSelected ? _levelColors[i] : Colors.black54,
                              ),
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _locationController,
                    focusNode: _focusNode,          // use the persistent focus node
                    decoration: InputDecoration(
                      hintText: "e.g., Library, Cafeteria",
                      labelText: "Tag this location",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text("Share"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _saveLocation,
                ),
              ],
            ),
            // ... rest of the widget tree unchanged ...
            const SizedBox(height: 8),
            const Text(
              "Your report will be visible to nearby Hops users.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            Text(
              "📡 Community Reports",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "Reports from other students near you appear here.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            if (communityList.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      "No reports yet. Walk around to see what others have shared!",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              )
            else
              ...communityList.map((report) {
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _levelColors[report.level],
                      child: Icon(_levelIcons[report.level],
                          color: Colors.white),
                    ),
                    title: Text(
                      report.location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _levelNames[report.level],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              }),
            const SizedBox(height: 24),
            Text(
              "Your Saved History",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 8),
            if (_records.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  "No records yet.",
                  style: TextStyle(color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              ..._records.map((record) {
                final loc = record[DatabaseHelper.vibeColLocation];
                final count = record[DatabaseHelper.vibeColDeviceCount];
                final ts = record[DatabaseHelper.vibeColTimestamp];
                final date = DateTime.fromMillisecondsSinceEpoch(ts as int);
                final id = record[DatabaseHelper.vibeColId];
                final level = count <= 2 ? 0 : count <= 5 ? 1 : count <= 10 ? 2 : 3;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _levelColors[level],
                      child: Icon(_levelIcons[level], color: Colors.white),
                    ),
                    title: Text(
                      loc.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _levelNames[level] +
                          " · ${date.hour}:${date.minute.toString().padLeft(2, '0')}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent),
                      onPressed: () => _deleteRecord(id as String),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _CommunityReport {
  final String location;
  final int count;
  final int level;
  final DateTime timestamp;
  _CommunityReport({
    required this.location,
    required this.count,
    required this.level,
    required this.timestamp,
  });
}