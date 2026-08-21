// lib/services/vibe_report_store.dart
//
// App-wide store for crowd-density reports heard from other students
// (VBT: advertisements). Pulled out of vibe_check_page.dart, which held
// them in widget State, for two reasons that were both real bugs:
//
//   1. Reports vanished the moment you left the page. VibeCheckPage is a
//      pushed route, so its State — and every report in it — was disposed
//      on back-navigation and rebuilt empty on return. A one-hour report
//      lifetime meant nothing when the list couldn't survive thirty
//      seconds of navigating away.
//
//   2. Nothing was heard unless the page was open. Detection lived in that
//      page's own scan-stream listener, so a report arriving while you
//      were anywhere else in the app was simply never seen — which is also
//      why the red dot only ever appeared *after* opening the feature,
//      rather than telling you there was something to open it for.
//
// Detection now runs in hops_app.dart's always-on scan handler and lands
// here; VibeCheckPage renders this and adds its own entries.
//
// Persisted to SharedPreferences so reports also survive the app being
// closed and reopened inside their lifetime — consistent with the rest of
// this app's small-local-state convention (see CLAUDE.md).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long a report from someone else stays live.
///
/// One hour, matching the campus lesson length: density is driven almost
/// entirely by where classes are, so a reading from the previous lesson
/// slot describes a room that has since emptied or filled. Was two
/// minutes, which was far too aggressive in the other direction — a VBT:
/// tag only broadcasts for 30 seconds, so a report you did manage to hear
/// disappeared almost immediately and the list was nearly always empty.
const Duration kVibeReportLifetime = Duration(hours: 1);

class VibeReport {
  final String location;
  final int level; // 0..3, see VibeCheckPage's level names/colors
  final DateTime timestamp;
  const VibeReport({
    required this.location,
    required this.level,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'location': location,
        'level': level,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  factory VibeReport.fromJson(Map<String, dynamic> j) => VibeReport(
        location: j['location'] as String,
        level: j['level'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
      );
}

class VibeReportStore {
  VibeReportStore._();
  static final VibeReportStore instance = VibeReportStore._();

  static const _prefsKey = 'vibe_reports_v1';

  /// Live reports, keyed by the advertisement that produced them (so the
  /// same location re-broadcast at a new level replaces the old entry
  /// rather than piling up).
  final ValueNotifier<Map<String, VibeReport>> reports =
      ValueNotifier<Map<String, VibeReport>>({});

  /// Report keys THIS device itself filed — the only ones the "Delete"
  /// action is offered on (vibe_check_page.dart). Local-only bookkeeping,
  /// same as LostFoundStore.myPostIds: nothing about authorship travels on
  /// the wire, a VBT: tag is anonymous same as always.
  final ValueNotifier<Set<String>> myReportKeys = ValueNotifier<Set<String>>({});

  static const _minePrefsKey = 'vibe_my_report_keys_v1';

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = (json.decode(raw) as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, VibeReport.fromJson(v as Map<String, dynamic>)));
        reports.value = decoded;
        prune();
      } catch (_) {
        // Corrupt/older shape — start clean rather than crash the feature.
      }
    }
    myReportKeys.value = (prefs.getStringList(_minePrefsKey) ?? const []).toSet();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      json.encode(reports.value.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<void> _persistMine() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_minePrefsKey, myReportKeys.value.toList());
  }

  /// Marks [key] as this device's own report — called right after filing
  /// one, so "Delete" stays offered on it even after leaving and
  /// reopening the page.
  void markMine(String key) {
    if (myReportKeys.value.contains(key)) return;
    myReportKeys.value = {...myReportKeys.value, key};
    _persistMine();
  }

  /// Removes [key] — the local half of deleting your own report. Callers
  /// also broadcast VBX: (see hops_app.dart's _deleteVibeReport) so nearby
  /// devices still actively hearing the original tag drop it too; this
  /// only ever handles this one device's own view/bookkeeping.
  void removeReport(String key) {
    if (!reports.value.containsKey(key) && !myReportKeys.value.contains(key)) return;
    final next = Map<String, VibeReport>.from(reports.value)..remove(key);
    reports.value = next;
    _persist();
    if (myReportKeys.value.contains(key)) {
      myReportKeys.value = {...myReportKeys.value}..remove(key);
      _persistMine();
    }
  }

  /// Records a report. Returns true only if this is a *new* sighting (a
  /// location not already live), so callers can badge/notify once rather
  /// than on every repeat — a VBT: tag re-broadcasts for 30 seconds and is
  /// therefore heard many times over.
  bool record({required String key, required String location, required int level}) {
    final isNew = !reports.value.containsKey(key);
    reports.value = {
      ...reports.value,
      key: VibeReport(location: location, level: level, timestamp: DateTime.now()),
    };
    _persist();
    return isNew;
  }

  /// Drops anything past its lifetime. Returns true if something went.
  bool prune() {
    final cutoff = DateTime.now().subtract(kVibeReportLifetime);
    final next = Map<String, VibeReport>.from(reports.value)
      ..removeWhere((_, r) => r.timestamp.isBefore(cutoff));
    if (next.length == reports.value.length) return false;
    reports.value = next;
    _persist();
    return true;
  }

  /// Newest first — the order the Vibe Check list renders in.
  List<VibeReport> sortedReports() =>
      reports.value.values.toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
}
