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
import 'package:client/services/hops_constants.dart';

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
  // Index into kStudyLocations, or null when the poster gave no location
  // (optional by design) or sent one this build does not know. Carried in
  // manufacturer data rather than the name — see hops_constants.dart's
  // kStudyLocationProtocolMarker for why.
  final int? locationIndex;

  /// Who posted this tag, as the truncated tag from its `SBO:` owner
  /// advertisement — null when that was never heard.
  ///
  /// Null is an ordinary state: the owner record is a separate broadcast
  /// (see kStudyOwnerPrefix), so a tag arrives fine without it. Its only
  /// job is to let a report name somebody.
  final String? senderTag;

  const StudyReport({
    required this.id,
    required this.subject,
    required this.timestamp,
    this.interestCount = 0,
    this.locationIndex,
    this.senderTag,
  });

  /// Display name for this tag's location, or null when it has none.
  String? get locationName => studyLocationName(locationIndex);

  StudyReport copyWith({
    DateTime? timestamp,
    int? interestCount,
    // Nullable field on a copyWith needs a sentinel to tell "leave it
    // alone" apart from "set it to null"; nothing needs to clear it, so
    // this only ever sets or preserves.
    int? locationIndex,
    String? senderTag,
  }) =>
      StudyReport(
        id: id,
        subject: subject,
        locationIndex: locationIndex ?? this.locationIndex,
        timestamp: timestamp ?? this.timestamp,
        interestCount: interestCount ?? this.interestCount,
        senderTag: senderTag ?? this.senderTag,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'subject': subject,
        'ts': timestamp.millisecondsSinceEpoch,
        'ic': interestCount,
        'loc': locationIndex,
        if (senderTag != null) 'sender': senderTag,
      };

  factory StudyReport.fromJson(Map<String, dynamic> j) => StudyReport(
        id: j['id'] as String,
        subject: j['subject'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
        // Absent in reports persisted before this field existed — default
        // to 0 rather than fail the whole decode.
        interestCount: j['ic'] as int? ?? 0,
        // Absent on anything persisted before this field existed.
        locationIndex: j['loc'] as int?,
        senderTag: j['sender'] as String?,
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
  bool record({
    required String id,
    required String subject,
    int? locationIndex,
  }) {
    final isNew = !reports.value.containsKey(id);
    final existing = reports.value[id];
    // Preserve whatever interest count this tag already has — every
    // re-broadcast of the same SBF: tag calls this again for the whole
    // advertise window, and without this it would reset to 0 on the very
    // next re-hear after someone showed interest.
    final existingCount = existing?.interestCount ?? 0;
    // Same reasoning for the location, with one extra wrinkle: the
    // location rides manufacturer data in the SCAN RESPONSE, which does
    // not necessarily arrive on every scan result that carries the name.
    // A re-hear without it must not wipe a location we already learned,
    // or it would flicker in and out of the list.
    reports.value = {
      ...reports.value,
      id: StudyReport(
        id: id,
        subject: subject,
        timestamp: DateTime.now(),
        interestCount: existingCount,
        locationIndex: locationIndex ?? existing?.locationIndex,
        // Same preservation reasoning as the two above: SBO: is its own
        // advertisement with no ordering against SBF:, so a re-heard tag
        // must not wipe an owner already learned.
        senderTag: existing?.senderTag ?? _pendingOwners.remove(id),
      ),
    };
    _persist();
    return isNew;
  }

  /// Records who posted [id], from its `SBO:` advertisement.
  ///
  /// Tolerates arriving before the tag itself, and never overwrites an
  /// owner already known — the first record heard for an id wins, so a
  /// later malformed or spoofed one cannot relabel an attributed tag.
  void recordOwner(String id, String senderTag) {
    final existing = reports.value[id];
    if (existing != null) {
      if (existing.senderTag != null) return;
      reports.value = {
        ...reports.value,
        id: existing.copyWith(senderTag: senderTag),
      };
      _persist();
      return;
    }
    _pendingOwners[id] = senderTag;
  }

  /// Owners heard before their tag. In memory only — an owner with no tag
  /// is worthless across a restart.
  final Map<String, String> _pendingOwners = {};

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
