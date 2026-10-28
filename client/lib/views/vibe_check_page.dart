import 'dart:async';
import 'package:flutter/material.dart';
import 'package:client/services/hops_constants.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:client/database/database_helper.dart';
import 'package:client/views/vibe_history_page.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/utils/report_content.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/services/vibe_report_store.dart';
import 'package:client/utils/profanity_filter.dart';


class VibeCheckPage extends StatefulWidget {
  final Stream<List<ScanResult>> radarStream;
  final Future<void> Function(String location, int count) onAdvertiseVibeTag;
  final Future<void> Function(String reportKey) onDeleteVibeReport;

  const VibeCheckPage({
    super.key,
    required this.radarStream,
    required this.onAdvertiseVibeTag,
    required this.onDeleteVibeReport,
  });

  @override
  State<VibeCheckPage> createState() => _VibeCheckPageState();
}

class _VibeCheckPageState extends State<VibeCheckPage> {
  // Reports themselves live in VibeReportStore, not here — see that file
  // for why (they used to be wiped every time this page was popped, and
  // were only ever collected while it happened to be open). This page
  // renders the store and adds its own entries; detection is in
  // hops_app.dart's always-on scan handler.
  final _store = VibeReportStore.instance;
  Timer? _expiryTimer;

  int _selectedCrowdLevel = 0;

  // "VBT:" (4) + ":" (1) + one level digit (1) = 6 bytes of framing.
  static final int _kLocationMaxLength = advertisementTextBudget(6);

  final TextEditingController _locationController = TextEditingController();
  final FocusNode _focusNode = FocusNode();     // explicit focus for the text field

  @override
  void initState() {
    super.initState();
    // Opening this page IS reading them — clear the badge on its card in
    // My Features and on the nav bar.
    UnreadTracker.instance.clear(UnreadSource.vibeCheck);
    _store.load();

    // Ticks the relative ages ("12m ago") as well as expiring anything
    // past its lifetime — an hour-old reading that still reads "just now"
    // would be worse than no timestamp at all.
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _store.prune();
      if (mounted) setState(() {});
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
    final location = censorProfanity(_locationController.text.trim());
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

    // Also show it in the live list straight away. Our own advertisement
    // is filtered out of our own scan results, so without this the report
    // you just filed is the one report you can't see.
    final key = "VBT:$location:$level";
    _store.record(key: key, location: location, level: level);
    _store.markMine(key);
    if (mounted) setState(() {});

    await widget.onAdvertiseVibeTag(location, level);

    _locationController.clear();
    _focusNode.unfocus();   // dismiss the keyboard after saving
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Saved $location as ${_levelNames[level]}")),
      );
    }
  }

  Future<void> _deleteReport(String key) async {
    _store.removeReport(key);
    if (mounted) setState(() {});
    await widget.onDeleteVibeReport(key);
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
    _expiryTimer?.cancel();
    _locationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _reportAge(DateTime timestamp) {
    final minutes = DateTime.now().difference(timestamp).inMinutes;
    if (minutes < 1) return "just now";
    return "${minutes}m ago";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    // The whole reason a report ever showed up late (or only after leaving
    // and reopening this page) was that nothing here was actually listening
    // to VibeReportStore.reports — detection runs continuously in
    // hops_app.dart's scan handler and writes straight into the store, but
    // this screen only ever redrew on its own 1-minute age-tick timer or on
    // a fresh initState from remounting. A report from another phone could
    // sit in the store, fully received, for up to a minute (or until you
    // backed out and back in) before this screen happened to rebuild and
    // notice it. ValueListenableBuilder rebuilds the moment the store
    // changes, which is what "arrives while I'm looking at the page" needs.
    return ValueListenableBuilder<Map<String, VibeReport>>(
      valueListenable: _store.reports,
      builder: (context, _, __) => ValueListenableBuilder<Set<String>>(
        valueListenable: _store.myReportKeys,
        builder: (context, mine, __) => _buildScaffold(context, theme, colors, mine),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, ThemeData theme, ColorScheme colors, Set<String> mine) {
    final communityList = _store.sortedReports();

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
                        color: isSelected ? _levelColors[i].withValues(alpha: 0.2) : colors.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected ? _levelColors[i] : colors.outline.withValues(alpha: 0.25),
                          width: 2,
                        ),
                        boxShadow: isSelected
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
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
                                color: isSelected ? _levelColors[i] : colors.onSurface.withValues(alpha: 0.6),
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
                    // Derived from the wire budget, not guessed. Was 24,
                    // which is the TEXT budget with no allowance for this
                    // format's own framing: "VBT:" + location + ":" +
                    // level costs 6 bytes on top, so a 21-character
                    // location produced a 27-byte name. That passed the
                    // old `> 29` guard and then failed on the radio with
                    // ADVERTISE_FAILED_DATA_TOO_LARGE — silently, because
                    // the failure only arrives on an async callback that
                    // ignored everything except flares. The report showed
                    // up locally and never left the phone.
                    maxLength: _kLocationMaxLength,
                    style: TextStyle(color: colors.onSurface),  // typed text visible
                    decoration: InputDecoration(
                      hintText: "e.g., Library, Cafeteria",
                      hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                      labelText: "Tag this location",
                      labelStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.7)),
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
              style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
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
              style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.5)),
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
                      Icon(Icons.travel_explore, size: 28, color: colors.onSurface.withValues(alpha: 0.2)),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(
                          "No reports yet. Walk around to see what others have shared!",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 12),
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
                                // Age matters as much as the level here —
                                // an hour-old reading and a fresh one look
                                // identical otherwise, and they mean very
                                // different things once a lesson has changed.
                                "${_levelNames[report.level]} · ${_reportAge(report.timestamp)}",
                                style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                              ),
                            ],
                          ),
                        ),
                        if (mine.contains("VBT:${report.location}:${report.level}"))
                          IconButton(
                            icon: Icon(Icons.delete_outline, size: 18, color: colors.error.withValues(alpha: 0.7)),
                            tooltip: "Delete",
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _deleteReport("VBT:${report.location}:${report.level}"),
                          )
                        else
                          // Vibe Check tags carry no sender at all (see
                          // VBT: in hops_app.dart) — this can only ever
                          // report the tag itself as spam/wrong, never a
                          // specific person, unlike Community Alerts'
                          // report action.
                          IconButton(
                            icon: Icon(Icons.flag_outlined, size: 18, color: colors.onSurface.withValues(alpha: 0.35)),
                            tooltip: "Report",
                            visualDensity: VisualDensity.compact,
                            onPressed: () => showReportContentSheet(
                              context,
                              contentType: 'vibe_check',
                              snapshotText: "${report.location}: ${_levelNames[report.level]}",
                              contentCreatedAt: report.timestamp,
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
