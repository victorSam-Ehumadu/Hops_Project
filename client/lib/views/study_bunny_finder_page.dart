// lib/views/study_bunny_finder_page.dart
//
// Study Bunny Finder — tag what you're studying right now, see who else
// nearby is studying the same thing (or anything else). Tap "I'm
// Interested" on someone else's tag to let them know, without either side
// ever learning who the other is (study tags carry no sender identity —
// see study_bunny_store.dart). Your own active tag gets a "Delete" action
// to end the session early.
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:client/services/hops_constants.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/utils/report_content.dart';
import 'package:client/utils/profanity_filter.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/services/study_bunny_store.dart';

/// 4-character base36 tag — see lost_found_board_page.dart's identical
/// helper for why this width is enough (not cryptographic, just needs to
/// be unlikely to collide with another LIVE tag).
String _generateTagId() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rng = Random();
  return List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
}

class StudyBunnyFinderPage extends StatefulWidget {
  final String myUsername;
  final Future<void> Function(String id, String subject,
      {int? locationIndex}) onAdvertiseStudyTag;
  final Future<void> Function(String id) onSendStudyInterest;
  final Future<void> Function(String id) onDeleteStudyTag;

  const StudyBunnyFinderPage({
    super.key,
    required this.myUsername,
    required this.onAdvertiseStudyTag,
    required this.onSendStudyInterest,
    required this.onDeleteStudyTag,
  });

  @override
  State<StudyBunnyFinderPage> createState() => _StudyBunnyFinderPageState();
}

class _StudyBunnyFinderPageState extends State<StudyBunnyFinderPage> {
  final _store = StudyBunnyStore.instance;
  Timer? _expiryTimer;
  Timer? _broadcastEndTimer;
  String? _myActiveId;

  // Index into kStudyLocations, or null for "not saying". Optional on
  // purpose: someone broadcasting that they are studying is not obliged to
  // say exactly where, and requiring it would make the quick path slower
  // for no benefit.
  int? _selectedLocationIndex;

  final TextEditingController _subjectController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  // Derived from the wire budget rather than guessed. Was 20, which left
  // no room for this format's framing: "SBF:" (4) + a 4-char id + ":" (1)
  // costs 9 bytes, so a 20-character subject produced a 29-byte name —
  // over the 26-byte ceiling, and so rejected by the radio after the send
  // had already appeared to succeed. Same silent failure Vibe Check had.
  static final int _subjectMaxLength = advertisementTextBudget(9);

  @override
  void initState() {
    super.initState();
    UnreadTracker.instance.clear(UnreadSource.studyBunny);
    _store.load();
    _expiryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _store.prune();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _broadcastEndTimer?.cancel();
    _subjectController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _startStudying() async {
    final subject = censorProfanity(_subjectController.text.trim());
    if (subject.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("What are you studying?")),
      );
      return;
    }
    final id = _generateTagId();
    // advertisementNameFits, not `.length > 29`. Two things were wrong with
    // that: 29 is not the ceiling (kAdvertisementNameMaxBytes is 26), and
    // `.length` counts UTF-16 code units, so an accented character or an
    // emoji in a subject counted as one while costing two to four bytes on
    // the wire. _subjectMaxLength keeps ASCII input inside the budget
    // already, which is why this never bit — but it was the same silent
    // over-long-name failure waiting for the first non-ASCII subject.
    if (!advertisementNameFits("SBF:$id:$subject")) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That's a bit long — try a shorter subject or course code.")),
      );
      return;
    }

    // Show our own tag immediately — our own advertisement is filtered out
    // of our own scan results (same reason Vibe Check does this), so
    // without it the session you just started is the one you can't see.
    _store.record(
        id: id, subject: subject, locationIndex: _selectedLocationIndex);
    if (mounted) setState(() => _myActiveId = id);

    await widget.onAdvertiseStudyTag(id, subject,
        locationIndex: _selectedLocationIndex);

    _broadcastEndTimer?.cancel();
    _broadcastEndTimer = Timer(kStudyTagAdvertiseDuration, () {
      if (mounted && _myActiveId == id) setState(() => _myActiveId = null);
    });

    _focusNode.unfocus();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Broadcasting \"$subject\" for the next ${kStudyTagAdvertiseDuration.inMinutes ~/ 60} hour.")),
      );
    }
  }

  /// What this device is currently broadcasting, including the location
  /// when one was chosen — so the poster can see exactly what others see.
  String _myActiveBroadcastLabel() {
    final report = _store.reports.value[_myActiveId];
    if (report == null) return 'Broadcasting:';
    final where = report.locationName;
    return where == null
        ? 'Broadcasting: ${report.subject}'
        : 'Broadcasting: ${report.subject} · $where';
  }

  Future<void> _deleteMyTag() async {
    final id = _myActiveId;
    if (id == null) return;
    _broadcastEndTimer?.cancel();
    _store.remove(id);
    setState(() => _myActiveId = null);
    await widget.onDeleteStudyTag(id);
  }

  Future<void> _expressInterest(StudyReport report) async {
    await widget.onSendStudyInterest(report.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Let them know you're interested in \"${report.subject}\"!")),
    );
  }

  String _reportAge(DateTime timestamp) {
    final minutes = DateTime.now().difference(timestamp).inMinutes;
    if (minutes < 1) return "just now";
    if (minutes < 60) return "${minutes}m ago";
    return "${minutes ~/ 60}h ago";
  }

  // ── "Where?" ─────────────────────────────────────────────────────────

  Widget _locationButton(ColorScheme colors) {
    final chosen = studyLocationName(_selectedLocationIndex);
    final isSet = chosen != null;
    final accent = isSet ? colors.primary : colors.onSurface;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _pickLocation,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: isSet
                ? colors.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            border: Border.all(
                color: accent.withValues(alpha: isSet ? 0.45 : 0.25)),
          ),
          child: Row(
            children: [
              Icon(Icons.place_outlined,
                  size: 16, color: accent.withValues(alpha: 0.8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  chosen ?? "Not saying",
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isSet ? FontWeight.bold : FontWeight.w500,
                    color: isSet
                        ? accent
                        : accent.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Icon(Icons.expand_more,
                  size: 18, color: accent.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickLocation() async {
    // Sentinel for "no venue": null is a real, meaningful choice here (the
    // location is optional on the wire), so it cannot double as "the sheet
    // was dismissed".
    const clear = -1;
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              const SizedBox(height: 14),
              const Text("Where are you studying?",
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.not_listed_location_outlined,
                          size: 20),
                      title: const Text("Not saying",
                          style: TextStyle(fontSize: 14)),
                      trailing: _selectedLocationIndex == null
                          ? const Icon(Icons.check, size: 20)
                          : null,
                      onTap: () => Navigator.pop(ctx, clear),
                    ),
                    const Divider(height: 1),
                    for (var i = 0; i < kStudyLocations.length; i++)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined, size: 20),
                        title: Text(kStudyLocations[i],
                            style: const TextStyle(fontSize: 14)),
                        trailing: _selectedLocationIndex == i
                            ? const Icon(Icons.check, size: 20)
                            : null,
                        onTap: () => Navigator.pop(ctx, i),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return; // dismissed
    setState(() => _selectedLocationIndex = picked == clear ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, StudyReport>>(
      valueListenable: _store.reports,
      builder: (context, _, __) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bunnies = _store.sortedReports();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Flexible(
          child: Text(
            "Study Bunny Finder",
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
              "What are you studying?",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colors.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              "Tag your subject or course code so other Hoppers nearby studying the same thing can find you.",
              style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 12),
            // Every session is a fixed hour, so there is no meeting time to
            // pick — which is worth saying out loud, because the first thing
            // people look for here is where to set one.
            //
            // The duration is read from kStudyTagAdvertiseDuration rather
            // than written as "1 hour", so this cannot quietly contradict
            // the code if that constant ever changes. It is also the reason
            // this says "an hour" and not "75 minutes": the 75 in
            // kStudyReportLifetime is how long a RECEIVED tag is kept
            // locally, deliberately a little longer than the on-air window
            // so a tag first heard near the end does not vanish moments
            // later. What a user is promised is the broadcast hour.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, size: 16, color: colors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Study sessions happen now, not later",
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Posting a tag says \"I'm studying this right now\" — "
                          "it isn't a meeting you schedule, so there's no time "
                          "to pick. It stays visible to Hoppers nearby for "
                          "${kStudyTagAdvertiseDuration.inMinutes ~/ 60} hour "
                          "and then stops on its own. Everyone you see below is "
                          "studying at this moment too.",
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.35,
                            color: colors.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_myActiveId != null) ...[
              HopsCard(
                radius: 14,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.wifi_tethering, color: colors.primary, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _myActiveBroadcastLabel(),
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _deleteMyTag,
                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                      label: const Text('End', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: colors.error, visualDensity: VisualDensity.compact),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _subjectController,
                      focusNode: _focusNode,
                      maxLength: _subjectMaxLength,
                      style: TextStyle(color: colors.onSurface),
                      decoration: InputDecoration(
                        hintText: "e.g., CS201, Organic Chem",
                        hintStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.5)),
                        labelText: "Subject / course",
                        labelStyle: TextStyle(color: colors.onSurface.withValues(alpha: 0.7)),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.menu_book),
                    label: const Text("Start"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _startStudying,
                  ),
                ],
              ),
                  const SizedBox(height: 10),
                  // A fixed list, not free text. One byte on the wire
                  // instead of ten (see hops_constants.dart's
                  // kStudyLocationProtocolMarker), and locations that
                  // actually group — free text gives "Library", "library"
                  // and "Libry" as three different places, so a list of
                  // who is studying where could not be grouped at all.
                  Text(
                    "Where? (optional)",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // One button, not a Wrap of 17 chips. The venue list
                  // outgrew chips when it was renamed: the picker took
                  // more height than everything else on this card
                  // combined, for something most people set once.
                  _locationButton(colors),
                ],
              ),
            // The "up to 1 hour" line that used to sit here is gone: the
            // note at the top of this screen now says the same thing, and
            // more prominently. Two copies of the same promise invites them
            // drifting apart.
            const SizedBox(height: 24),
            Row(
              children: [
                Icon(Icons.cruelty_free, size: 16, color: colors.primary),
                const SizedBox(width: 6),
                Text(
                  "Nearby Study Bunnies",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: colors.primary),
                ),
                if (bunnies.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(100)),
                    child: Text("${bunnies.length}",
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (bunnies.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.local_library_outlined, size: 28, color: colors.onSurface.withValues(alpha: 0.2)),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: Text(
                          "No study bunnies nearby yet. Tag a subject above to be the first!",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...bunnies.map((report) {
                final isMine = report.id == _myActiveId;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: HopsCard(
                    radius: 16,
                    padding: const EdgeInsets.all(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: isMine ? null : () => _expressInterest(report),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: colors.primary,
                            child: const Text('🐰', style: TextStyle(fontSize: 16)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(report.subject,
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                    // Visible on every device that has this
                                    // tag, not just the poster's — see
                                    // study_bunny_store.dart's interestCount
                                    // and hops_app.dart's SBC: broadcast.
                                    if (report.interestCount > 0) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: colors.primary.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(100),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.front_hand_outlined, size: 11, color: colors.primary),
                                            const SizedBox(width: 3),
                                            Text(
                                              '${report.interestCount}',
                                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: colors.primary),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                // Location on its own line with a pin, so
                                // "where" is scannable down the list —
                                // which is the point of the feature. Only
                                // rendered when there is one: it is
                                // optional, and tags from an older build
                                // carry none.
                                if (report.locationName != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        Icon(Icons.place_outlined,
                                            size: 11, color: colors.primary),
                                        const SizedBox(width: 3),
                                        Flexible(
                                          child: Text(
                                            report.locationName!,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: colors.primary,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Text(
                                  isMine ? "Your session · ${_reportAge(report.timestamp)}" : "Studying · ${_reportAge(report.timestamp)}",
                                  style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                                ),
                              ],
                            ),
                          ),
                          if (!isMine) ...[
                            TextButton.icon(
                              onPressed: () => _expressInterest(report),
                              icon: const Icon(Icons.front_hand_outlined, size: 15),
                              label: const Text('Interested', style: TextStyle(fontSize: 11)),
                              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            ),
                            // Study tags carry no sender identity on the
                            // wire (same as Vibe Check's VBT: tags) — only
                            // the tag itself can be reported.
                            IconButton(
                              icon: Icon(Icons.flag_outlined, size: 18, color: colors.onSurface.withValues(alpha: 0.35)),
                              tooltip: "Report",
                              visualDensity: VisualDensity.compact,
                              onPressed: () => showReportContentSheet(
                                context,
                                contentType: 'study_bunny',
                                snapshotText: report.subject,
                                contentCreatedAt: report.timestamp,
                              ),
                            ),
                          ],
                        ],
                      ),
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
