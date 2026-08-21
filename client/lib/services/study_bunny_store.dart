// lib/services/study_bunny_store.dart
//
// App-wide store for "studying right now" tags heard from other students
// (SBF: advertisements — Study Bunny Finder). Structured identically to
// vibe_report_store.dart for the same two reasons that store exists as its
// own file rather than living in its page's State: a report shouldn't
// vanish just because the page holding it got popped, and detection needs
// to run continuously (hops_app.dart's always-on scan handler) rather than
// only while the page happens to be open.
//
// Each tag carries a short id (see hops_app.dart's _advertiseStudyTag) —
// needed for two things a plain "SBF:<subject>" tag couldn't do: tapping
// "I'm interested" (SBI:<id>) so the poster's device can recognize a
// response is actually addressed to their own active session, and deleting
// your own tag early (SBX:<id>).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long a study tag from someone else stays live — a bit longer than
/// kStudyTagAdvertiseDuration itself (the actual on-air window) so a tag
/// heard right before the sender's broadcast ends doesn't immediately
/// vanish from the list the moment it stops re-transmitting.
const Duration kStudyReportLifetime = Duration(minutes: 75);

/// How long a "I'm studying X" tag actively broadcasts once sent — a full
/// study session, not a brief snapshot.
const Duration kStudyTagAdvertiseDuration = Duration(hours: 1);

class StudyReport {
  final String id;
  final String subject;
  final DateTime timestamp;
  // How many "I'm Interested" taps this tag has received, as last reported
  // by the ORIGINAL poster's device (see hops_app.dart's SBC: broadcast) —
  // visible to every device that already has this report, not just the
  // poster, so the count reads the same everywhere it's shown.
  final int interestCount;
  const StudyReport({
    required this.id,
    required this.subject,
    required this.timestamp,
    this.interestCount = 0,
  });

  StudyReport copyWith({DateTime? timestamp, int? interestCount}) => StudyReport(
        id: id,
        subject: subject,
        timestamp: timestamp ?? this.timestamp,
        interestCount: interestCount ?? this.interestCount,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'subject': subject, 'ts': timestamp.millisecondsSinceEpoch, 'ic': interestCount};

  factory StudyReport.fromJson(Map<String, dynamic> j) => StudyReport(
        id: j['id'] as String,
        subject: j['subject'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        // Absent in reports persisted before this field existed — default
        // to 0 rather than fail the whole decode.
        interestCount: j['ic'] as int? ?? 0,
      );
}

class StudyBunnyStore {
  StudyBunnyStore._();
  static final StudyBunnyStore instance = StudyBunnyStore._();

  static const _prefsKey = 'study_bunny_reports_v2';

  /// Live reports, keyed by tag id.
  final ValueNotifier<Map<String, StudyReport>> reports = ValueNotifier<Map<String, StudyReport>>({});

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final decoded = (json.decode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, StudyReport.fromJson(v as Map<String, dynamic>)));
      reports.value = decoded;
      prune();
    } catch (_) {
      // Corrupt/older shape — start clean rather than crash the feature.
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, json.encode(reports.value.map((k, v) => MapEntry(k, v.toJson()))));
  }

  /// Records a report. Returns true only for a genuinely new key, so
  /// callers can badge/notify once rather than on every repeat — a tag
  /// re-broadcasts for the whole kStudyTagAdvertiseDuration window and is
  /// therefore heard many times over.
  bool record({required String id, required String subject}) {
    final isNew = !reports.value.containsKey(id);
    // Preserve whatever interest count this tag already has — every
    // re-broadcast of the same SBF: tag calls this again for the whole
    // advertise window, and without this it would reset to 0 on the very
    // next re-hear after someone showed interest.
    final existingCount = reports.value[id]?.interestCount ?? 0;
    reports.value = {
      ...reports.value,
      id: StudyReport(id: id, subject: subject, timestamp: DateTime.now(), interestCount: existingCount),
    };
    _persist();
    return isNew;
  }

  /// Applies an interest-count update heard over the air (SBC:) — a no-op
  /// if this device never heard the tag's own SBF: in the first place
  /// (nothing to attach a count to) or if the count hasn't actually
  /// changed. Returns whether it changed anything, so callers can decide
  /// whether a rebuild/badge is warranted.
  bool setInterestCount(String id, int count) {
    final existing = reports.value[id];
    if (existing == null || existing.interestCount == count) return false;
    reports.value = {...reports.value, id: existing.copyWith(interestCount: count)};
    _persist();
    return true;
  }

  /// Bumps [id]'s own interest count by one — called by the ORIGINAL
  /// poster's device the moment it recognizes an SBI: reply is addressed
  /// to its own active session (hops_app.dart). Returns the new count for
  /// the caller to broadcast via SBC:, or null if this device isn't
  /// tracking that report (shouldn't happen for your own active tag, but
  /// guards against it rather than assuming).
  int? incrementInterest(String id) {
    final existing = reports.value[id];
    if (existing == null) return null;
    final next = existing.copyWith(interestCount: existing.interestCount + 1);
    reports.value = {...reports.value, id: next};
    _persist();
    return next.interestCount;
  }

  /// Removes [id] — used both when the poster deletes their own tag early
  /// (SBX:) and when it's simply pruned. See hops_app.dart's
  /// _deleteStudyTag for the broadcast half of a user-initiated delete.
  void remove(String id) {
    if (!reports.value.containsKey(id)) return;
    final next = Map<String, StudyReport>.from(reports.value)..remove(id);
    reports.value = next;
    _persist();
  }

  bool prune() {
    final cutoff = DateTime.now().subtract(kStudyReportLifetime);
    final next = Map<String, StudyReport>.from(reports.value)
      ..removeWhere((_, r) => r.timestamp.isBefore(cutoff));
    if (next.length == reports.value.length) return false;
    reports.value = next;
    _persist();
    return true;
  }

  List<StudyReport> sortedReports() =>
      reports.value.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
}
