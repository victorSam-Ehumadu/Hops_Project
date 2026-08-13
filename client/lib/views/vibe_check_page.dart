import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/views/vibe_history_page.dart';
import 'package:client/widgets/hops_card.dart';

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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Saved $location as ${_levelNames[level]}")),
      );
    }
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
        actions: [
          TextButton.icon(
            icon: Icon(Icons.history, color: colors.primary, size: 20),
            label: Text(
              "History",
              style: TextStyle(color: colors.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const VibeHistoryPage())),
          ),
          const SizedBox(width: 4),
        ],
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
                        color: isSelected ? _levelColors[i].withOpacity(0.2) : colors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected ? _levelColors[i] : colors.outline.withOpacity(0.25),
                          width: 2,
                        ),
                        boxShadow: isSelected
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
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
                                color: isSelected ? _levelColors[i] : colors.onSurface.withOpacity(0.6),
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
                    focusNode: _focusNode,
                    style: TextStyle(color: colors.onSurface),  // typed text visible
                    decoration: InputDecoration(
                      hintText: "e.g., Library, Cafeteria",
                      hintStyle: TextStyle(color: colors.onSurface.withOpacity(0.5)),
                      labelText: "Tag this location",
                      labelStyle: TextStyle(color: colors.onSurface.withOpacity(0.7)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.primary, width: 1.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colors.primary, width: 2),
                      ),
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
            const SizedBox(height: 8),
            Text(
              "Your report will be visible to nearby Hops users.",
              style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.5)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            // Same header treatment as the Home tab's friend-request tray —
            // icon + title + a count badge that only appears once there's
            // something to count.
            Row(
              children: [
                Icon(Icons.wifi_tethering, size: 16, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  "Community Reports",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: colors.primary,
                  ),
                ),
                if (communityList.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Text(
                      "${communityList.length}",
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              "Reports from other students near you appear here.",
              style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.5)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            if (communityList.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.travel_explore, size: 28, color: colors.onSurface.withOpacity(0.2)),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(
                          "No reports yet. Walk around to see what others have shared!",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurface.withOpacity(0.5), fontSize: 12),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...communityList.map((report) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: HopsCard(
                    radius: 16,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: _levelColors[report.level],
                          child: Icon(_levelIcons[report.level], color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                report.location,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _levelNames[report.level],
                                style: TextStyle(fontSize: 11, color: colors.onSurface.withOpacity(0.5)),
                              ),
                            ],
                          ),
                        ),
                      ],
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