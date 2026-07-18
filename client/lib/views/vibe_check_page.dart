import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/theme/hops_theme.dart';

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

  // Manual crowd level selection
  int _selectedCrowdLevel = 0; // 0=Quiet, 1=Moderate, 2=Busy, 3=Packed

  final TextEditingController _locationController = TextEditingController();

  List<Map<String, dynamic>> _records = [];

  // Community reports received via BLE
  final Map<String, _CommunityReport> _communityReports = {};

  @override
  void initState() {
    super.initState();

    // Listen to the radar stream to catch community VBT advertisements
    _streamSub = widget.radarStream.listen((results) {
      print("📡 VibeCheck stream received ${results.length} results");
      for (final r in results) {
        final advName = r.advertisementData.advName;
        if (advName.startsWith("VBT:")) {
          print("🏷️ Found VBT tag: $advName");
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
            }
          }
        }
      }
      // Remove old reports after 2 minutes
      final now = DateTime.now();
      _communityReports.removeWhere(
              (key, report) => now.difference(report.timestamp).inMinutes > 2);
      if (mounted) setState(() {});
    });

    _loadRecords();
  }

  int _levelToApproxCount(int level) {
    switch (level) {
      case 0: return 1; // Quiet
      case 1: return 4; // Moderate
      case 2: return 8; // Busy
      case 3: return 15; // Packed
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

    // Save locally
    final record = {
      DatabaseHelper.vibeColId: const Uuid().v4(),
      DatabaseHelper.vibeColLocation: location,
      DatabaseHelper.vibeColDeviceCount: approxCount,
      DatabaseHelper.vibeColTimestamp:
      DateTime.now().millisecondsSinceEpoch,
    };
    await DatabaseHelper.instance.insertVibeRecord(record);

    // Advertise to other Hops users
    await widget.onAdvertiseVibeTag(location, level);

    _locationController.clear();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final communityList = _communityReports.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: HopsTheme.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text("Vibe Check", style: TextStyle(fontWeight: FontWeight.bold, color: HopsTheme.primary)),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Manual Crowd Level Selection
            const Text(
              "How crowded is your spot?",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: HopsTheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(4, (i) {
                final isSelected = _selectedCrowdLevel == i;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCrowdLevel = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _levelColors[i].withOpacity(0.2)
                          : Colors.white.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color:
                        isSelected ? _levelColors[i] : Colors.grey.shade300,
                        width: 2,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(_levelIcons[i],
                            color: _levelColors[i], size: 28),
                        const SizedBox(height: 4),
                        Text(
                          _levelNames[i],
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color:
                            isSelected ? _levelColors[i] : Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 24),

            // Tag Location
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _locationController,
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
                    backgroundColor: HopsTheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _saveLocation,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              "Your report will be visible to nearby Hops users.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),

            const SizedBox(height: 24),

            // Community Reports
            const Text(
              "📡 Community Reports",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: HopsTheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              "Reports from other students near you appear here.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (communityList.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    "No reports yet. Walk around to see what others have shared!",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
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
                    title: Text(report.location),
                    subtitle: Text(_levelNames[report.level]),
                  ),
                );
              }),

            const SizedBox(height: 24),
            // Your Saved History
            const Text(
              "Your Saved History",
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: HopsTheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            if (_records.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  "No records yet.",
                  style: TextStyle(color: Colors.grey),
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
                    title: Text(loc.toString()),
                    subtitle: Text(
                      _levelNames[level] +
                          " · ${date.hour}:${date.minute.toString().padLeft(2, '0')}",
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