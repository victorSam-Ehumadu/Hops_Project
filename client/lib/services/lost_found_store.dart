// lib/services/lost_found_store.dart
//
// App-wide store for Lost & Found board posts (LNF: advertisements) and
// their resolution (LNR: — "this item's no longer lost," see
// hops_app.dart). Structured like vibe_report_store.dart/
// study_bunny_store.dart — detection runs continuously in hops_app.dart's
// always-on scan handler, not inside this feature's page, for the same
// reasons those two exist as their own files (a report shouldn't vanish on
// back-navigation, and shouldn't only ever be heard while the page happens
// to be open).
//
// Unlike Vibe Check/Study Bunny Finder, a Lost & Found post is also
// RELAYED one hop further by every device that hears it for the first time
// (see hops_app.dart's _scheduleEmgRelay, reused here) — a lost item report
// is exactly the kind of thing that should reach beyond direct BLE range
// (roughly one floor), the same reasoning Emergency Flare relaying already
// uses. Resolution (LNR:) relays the same way, so "found it" reaches
// everyone the original post did.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LostFoundType { lost, found }

/// A post stays visible on the board for a full day — unlike a crowd
/// report or a study session, "I lost my keys" is still relevant hours
/// later, and the whole point of a Lost & Found board is that it persists
/// past the moment it was posted. Resolving it early (see resolve()) is
/// how it actually leaves the board sooner than this.
const Duration kLostFoundPostLifetime = Duration(hours: 24);

class LostFoundPost {
  final String postId;
  final LostFoundType type;
  final String object;
  final String location;
  final DateTime timestamp;
  const LostFoundPost({
    required this.postId,
    required this.type,
    required this.object,
    required this.location,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'postId': postId,
        'type': type.index,
        'object': object,
        'location': location,
        'ts': timestamp.millisecondsSinceEpoch,
      };

  factory LostFoundPost.fromJson(Map<String, dynamic> j) => LostFoundPost(
        postId: j['postId'] as String,
        type: LostFoundType.values[(j['type'] as int).clamp(0, LostFoundType.values.length - 1)],
        object: j['object'] as String,
        location: j['location'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['ts'] as int),
      );
}

class LostFoundStore {
  LostFoundStore._();
  static final LostFoundStore instance = LostFoundStore._();

  static const _prefsKey = 'lost_found_posts_v2';
  static const _minePrefsKey = 'lost_found_my_post_ids_v1';

  /// Live posts, keyed by postId — a post re-heard via relay just refreshes
  /// against the same key rather than duplicating.
  final ValueNotifier<Map<String, LostFoundPost>> posts = ValueNotifier<Map<String, LostFoundPost>>({});

  /// postIds this device itself posted — the only ones the board's "Mark
  /// as Found" / "Delete" actions are offered on. Local-only bookkeeping;
  /// nothing about authorship travels on the wire (posts are anonymous,
  /// same as Vibe Check/Study Bunny Finder), so this is simply "did I post
  /// this from THIS device," not a verifiable claim.
  final ValueNotifier<Set<String>> myPostIds = ValueNotifier<Set<String>>({});

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final decoded = (json.decode(raw) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, LostFoundPost.fromJson(v as Map<String, dynamic>)));
        posts.value = decoded;
        prune();
      } catch (_) {
        // Corrupt/older shape — start clean rather than crash the feature.
      }
    }
    myPostIds.value = (prefs.getStringList(_minePrefsKey) ?? const []).toSet();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, json.encode(posts.value.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Future<void> _persistMine() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_minePrefsKey, myPostIds.value.toList());
  }

  /// Records a post — first sighting (own post, or someone else's heard
  /// live/relayed) all funnel through here. Returns true only if [postId]
  /// is genuinely new, so callers badge/notify once, not on every relay hop.
  bool record({
    required String postId,
    required LostFoundType type,
    required String object,
    required String location,
  }) {
    final isNew = !posts.value.containsKey(postId);
    posts.value = {
      ...posts.value,
      postId: LostFoundPost(postId: postId, type: type, object: object, location: location, timestamp: DateTime.now()),
    };
    _persist();
    return isNew;
  }

  /// Marks [postId] as this device's own post — called right after posting,
  /// so the board offers "Mark as Found"/"Delete" on it even after leaving
  /// and reopening the page (as long as the post itself hasn't expired).
  void markMine(String postId) {
    if (myPostIds.value.contains(postId)) return;
    myPostIds.value = {...myPostIds.value, postId};
    _persistMine();
  }

  /// Removes [postId] — the local half of resolving a post ("found it") or
  /// deleting one. Callers also broadcast LNR: (see hops_app.dart's
  /// _resolveLostFound) so other devices remove their copy too; this only
  /// ever handles this one device's own view/bookkeeping.
  void resolve(String postId) {
    if (!posts.value.containsKey(postId) && !myPostIds.value.contains(postId)) return;
    final nextPosts = Map<String, LostFoundPost>.from(posts.value)..remove(postId);
    posts.value = nextPosts;
    _persist();
    if (myPostIds.value.contains(postId)) {
      myPostIds.value = {...myPostIds.value}..remove(postId);
      _persistMine();
    }
  }

  bool prune() {
    final cutoff = DateTime.now().subtract(kLostFoundPostLifetime);
    final next = Map<String, LostFoundPost>.from(posts.value)
      ..removeWhere((_, p) => p.timestamp.isBefore(cutoff));
    if (next.length == posts.value.length) return false;
    posts.value = next;
    _persist();
    return true;
  }

  List<LostFoundPost> sortedPosts() =>
      posts.value.values.toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
}
