// lib/services/unread_tracker.dart
//
// One place that knows "has something arrived that the user hasn't looked
// at yet", per source, so the red dots on the bottom nav tabs and on the
// My Features cards can't drift out of sync with each other or with what
// actually happened.
//
// Deliberately a plain ValueNotifier-backed singleton rather than a new
// state-management dependency: HopsApp already drives every other
// cross-screen signal this way (see main.dart's chatPingRequest,
// nearbyConnectionsSessionCount, navBarPillHeightNotifier), and a badge is
// exactly the kind of thing a ValueListenableBuilder handles without any
// extra machinery.
//
// Persistence: unread state survives an app restart (SharedPreferences),
// because the alternative is worse — a notification arriving while the app
// is closed would light up a system notification the user taps, only for
// the app to open with no badge showing them where to go.
//
// This tracks *unread markers only*, never message content. The actual
// messages live where they always have (sqflite for 1:1 chat,
// SharedPreferences for Community Alerts, Supabase for notifications).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every distinct thing that can raise a badge. The nav-tab dots and the
/// feature-card dots both read from this same set — see
/// UnreadTracker.navTabSources / featureIdFor.
enum UnreadSource {
  directMessage,   // 1:1 chat (Contacts tab)
  communityAlerts, // Alerts tab
  notifications,   // admin warnings etc. (Contacts tab's bell)
  vibeCheck,       // a new crowd report nearby (Vibe Check feature)
  taskReminder,    // a task came due (Task Tracker feature)
  watchMe,         // watch request / buddy alert (Watch Me feature)
  hopsShare,       // an incoming file (Hops Share feature)
  studyBunny,      // a new study tag nearby (Study Bunny Finder feature)
  lostFound,       // a new lost/found post nearby (Lost & Found feature)
}

class UnreadTracker {
  UnreadTracker._();
  static final UnreadTracker instance = UnreadTracker._();

  static const _prefsKey = 'unread_sources_v1';

  /// The currently-unread sources. Listeners rebuild whenever this changes.
  final ValueNotifier<Set<UnreadSource>> unread =
      ValueNotifier<Set<UnreadSource>>(<UnreadSource>{});

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? const [];
    unread.value = stored
        .map((name) => UnreadSource.values.where((s) => s.name == name))
        .expand((matches) => matches) // unknown names (older/newer build) drop out
        .toSet();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, unread.value.map((s) => s.name).toList());
  }

  /// Something arrived from [source] that the user hasn't seen.
  void mark(UnreadSource source) {
    if (unread.value.contains(source)) return;
    unread.value = {...unread.value, source};
    _persist();
  }

  /// The user has now looked at [source] — called when the relevant tab or
  /// feature page is opened.
  void clear(UnreadSource source) {
    if (!unread.value.contains(source)) return;
    unread.value = {...unread.value}..remove(source);
    _persist();
  }

  bool has(UnreadSource source) => unread.value.contains(source);

  /// Which sources light up which bottom-nav tab index in HopsApp. Home
  /// (0), Features (3) and My Features (4) have no direct sources of their
  /// own — a feature's badge shows on its own card inside My Features
  /// instead, which is more precise than a dot on a tab holding eight
  /// unrelated things. My Features (4) is the exception: it also carries a
  /// dot when any feature underneath it does, so the badge is reachable
  /// without opening the tab to discover it.
  static const Map<int, List<UnreadSource>> navTabSources = {
    1: [UnreadSource.directMessage, UnreadSource.notifications],
    2: [UnreadSource.communityAlerts],
    4: [
      UnreadSource.vibeCheck,
      UnreadSource.taskReminder,
      UnreadSource.watchMe,
      UnreadSource.hopsShare,
      UnreadSource.studyBunny,
      UnreadSource.lostFound,
    ],
  };

  /// The feature-catalog id (see models/feature_item.dart) each
  /// feature-scoped source belongs to, for the dot on its card. Sources not
  /// listed here aren't features and never badge a card.
  static const Map<UnreadSource, int> featureIds = {
    UnreadSource.watchMe: 2,
    UnreadSource.vibeCheck: 5,
    UnreadSource.taskReminder: 9,
    UnreadSource.hopsShare: 11,
    UnreadSource.studyBunny: 15,
    UnreadSource.lostFound: 16,
  };

  /// True if the given feature card should show a dot.
  bool hasForFeature(int featureId) => featureIds.entries
      .any((e) => e.value == featureId && unread.value.contains(e.key));

  /// True if the given bottom-nav tab should show a dot.
  bool hasForNavTab(int tabIndex) =>
      (navTabSources[tabIndex] ?? const []).any(unread.value.contains);
}
