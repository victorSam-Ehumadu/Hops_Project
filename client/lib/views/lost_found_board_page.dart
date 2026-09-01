// lib/views/lost_found_board_page.dart
//
// Lost & Found board — post "lost my student card near the library" (or
// "found a blue backpack") and it relays hop-to-hop the same way Emergency
// Flare does, reaching beyond direct BLE range. See lost_found_store.dart's
// header comment for why this one relays and Vibe Check/Study Bunny
// Finder's tags don't.
//
// A post is two fields — object and location — not one freeform line,
// both for both Lost and Found (a Found post is "found this object at this
// location," same shape as a Lost one). Your own posts get "Mark as
// Found"/"Delete" — either one removes the post everywhere it's already
// spread to (see hops_app.dart's _resolveLostFound and LostFoundStore's
// resolve()), not just on this device.
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/utils/report_content.dart';
import 'package:client/utils/profanity_filter.dart';
import 'package:client/services/unread_tracker.dart';
import 'package:client/services/lost_found_store.dart';

/// 4-character base36 tag, e.g. "K3F9" — just needs to be unlikely to
/// collide with another post live on the board at the same time (36^4 ≈
/// 1.7M combinations), not cryptographically unique.
String _generatePostId() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final rng = Random();
  return List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
}

class LostFoundBoardPage extends StatefulWidget {
  final Future<void> Function(String postId, LostFoundType type, String object, String location)
      onAdvertiseLostFound;
  final Future<void> Function(String postId) onResolveLostFound;

  const LostFoundBoardPage({
    super.key,
    required this.onAdvertiseLostFound,
    required this.onResolveLostFound,
  });

  @override
  State<LostFoundBoardPage> createState() => _LostFoundBoardPageState();
}

class _LostFoundBoardPageState extends State<LostFoundBoardPage> {
  final _store = LostFoundStore.instance;
  Timer? _expiryTimer;
  LostFoundType _type = LostFoundType.lost;
  final TextEditingController _objectController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // Posts are chunked across multiple BLE advertisements and reassembled
  // (see hops_constants.dart's encodeLostFoundChunk/decodeLostFoundChunk),
  // so these aren't limited to a single ~29-byte packet the way they used
  // to be — up to 8 chunks' worth (152 characters) is the real ceiling,
  // far more than either field needs.
  static const int _objectMaxLength = 30;
  static const int _locationMaxLength = 30;

  @override
  void initState() {
    super.initState();
    UnreadTracker.instance.clear(UnreadSource.lostFound);
    _store.load();
    _expiryTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _store.prune();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _objectController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final object = censorProfanity(_objectController.text.trim());
    final location = censorProfanity(_locationController.text.trim());
    if (object.isEmpty || location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_type == LostFoundType.lost
            ? "What did you lose, and where?"
            : "What did you find, and where?")),
      );
      return;
    }

    final postId = _generatePostId();
    _store.record(postId: postId, type: _type, object: object, location: location);
    _store.markMine(postId);
    if (mounted) setState(() {});

    await widget.onAdvertiseLostFound(postId, _type, object, location);

    _objectController.clear();
    _locationController.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Posted to the board — spreading to nearby devices.")),
      );
    }
  }

  Future<void> _resolve(String postId) async {
    _store.resolve(postId);
    if (mounted) setState(() {});
    await widget.onResolveLostFound(postId);
  }

  String _postAge(DateTime timestamp) {
    final d = DateTime.now().difference(timestamp);
    if (d.inMinutes < 1) return "just now";
    if (d.inHours < 1) return "${d.inMinutes}m ago";
    return "${d.inHours}h ago";
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, LostFoundPost>>(
      valueListenable: _store.posts,
      builder: (context, _, __) => ValueListenableBuilder<Set<String>>(
        valueListenable: _store.myPostIds,
        builder: (context, mine, __) => _buildScaffold(context, mine),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, Set<String> mine) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final board = _store.sortedPosts();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.primary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Flexible(
          child: Text(
            "Lost & Found",
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
              "Post to the board",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colors.primary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _TypeToggle(
                    label: 'Lost',
                    icon: Icons.search,
                    color: Colors.redAccent,
                    selected: _type == LostFoundType.lost,
                    onTap: () => setState(() => _type = LostFoundType.lost),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _TypeToggle(
                    label: 'Found',
                    icon: Icons.check_circle_outline,
                    color: Colors.green,
                    selected: _type == LostFoundType.found,
                    onTap: () => setState(() => _type = LostFoundType.found),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _objectController,
              maxLength: _objectMaxLength,
              style: TextStyle(color: colors.onSurface),
              decoration: InputDecoration(
                labelText: _type == LostFoundType.lost ? "What did you lose?" : "What did you find?",
                hintText: "e.g., Backpack",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _locationController,
              maxLength: _locationMaxLength,
              style: TextStyle(color: colors.onSurface),
              decoration: InputDecoration(
                labelText: _type == LostFoundType.lost ? "Where did you lose it?" : "Where did you find it?",
                hintText: "e.g., Library",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.campaign_outlined),
                label: const Text("Post to the board"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _post,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Spreads device-to-device — no internet or server involved. "
              "Stays on the board for ${kLostFoundPostLifetime.inHours} hours, or until resolved.",
              style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Icon(Icons.pin_drop_outlined, size: 16, color: colors.primary),
                const SizedBox(width: 6),
                Text("The Board",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: colors.primary)),
                if (board.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(100)),
                    child: Text("${board.length}",
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (board.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined, size: 28, color: colors.onSurface.withValues(alpha: 0.2)),
                      const SizedBox(height: 6),
                      Text(
                        "Nothing posted nearby yet.",
                        style: TextStyle(color: colors.onSurface.withValues(alpha: 0.5), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...board.map((post) {
                final isLost = post.type == LostFoundType.lost;
                final color = isLost ? Colors.redAccent : Colors.green;
                final isMine = mine.contains(post.postId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: HopsCard(
                    radius: 16,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: color,
                              child: Icon(isLost ? Icons.search : Icons.check_circle_outline,
                                  color: Colors.white, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(post.object,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  Text(
                                    "${isLost ? 'Lost' : 'Found'} near ${post.location} · ${_postAge(post.timestamp)}",
                                    style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.5)),
                                  ),
                                ],
                              ),
                            ),
                            if (!isMine)
                              // No sender identity travels on the wire
                              // (same deliberate anonymity as Vibe Check/
                              // Study Bunny Finder) — only the post itself
                              // can be reported, not a specific person.
                              IconButton(
                                icon: Icon(Icons.flag_outlined, size: 18, color: colors.onSurface.withValues(alpha: 0.35)),
                                tooltip: "Report",
                                visualDensity: VisualDensity.compact,
                                onPressed: () => showReportContentSheet(
                                  context,
                                  contentType: 'lost_found',
                                  snapshotText: "${post.object} @ ${post.location}",
                                  contentCreatedAt: post.timestamp,
                                ),
                              ),
                          ],
                        ),
                        if (isMine) ...[
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (isLost)
                                TextButton.icon(
                                  onPressed: () => _resolve(post.postId),
                                  icon: const Icon(Icons.check_circle_outline, size: 16),
                                  label: const Text('Mark as Found', style: TextStyle(fontSize: 12)),
                                  style: TextButton.styleFrom(foregroundColor: Colors.green, visualDensity: VisualDensity.compact),
                                ),
                              TextButton.icon(
                                onPressed: () => _resolve(post.postId),
                                icon: const Icon(Icons.delete_outline, size: 16),
                                label: const Text('Delete', style: TextStyle(fontSize: 12)),
                                style: TextButton.styleFrom(foregroundColor: colors.error, visualDensity: VisualDensity.compact),
                              ),
                            ],
                          ),
                        ],
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

class _TypeToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _TypeToggle({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : colors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? color : colors.outline.withValues(alpha: 0.25), width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? color : colors.onSurface.withValues(alpha: 0.5)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: selected ? color : colors.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
