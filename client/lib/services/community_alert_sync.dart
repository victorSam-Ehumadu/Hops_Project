// Server-backed catch-up for Community Alerts.
//
// WHAT THIS IS FOR
//
// Community Alerts were BLE-only: an admin's alert cycled chunked
// advertisement names for about a minute and was then gone. A student
// whose Bluetooth was off at that moment never got it and never could,
// and a student who had never been online dropped it even with Bluetooth
// on — the receiver only accepts a CA: message whose sender tag resolves,
// via KeyDirectory, to a cached account with role 'admin', and
// KeyDirectory syncs over the internet.
//
// This is the catch-up path. BLE stays primary: instant, works with no
// internet at all, which is the point of the app. This collects whatever
// a device missed, next time it is online.
//
//   Bluetooth on,  internet off  -> BLE delivers now
//   Bluetooth off, internet on   -> this delivers on the next poll
//   both off                     -> delivered when either comes back
//
// WHY THIS DOES NOT CONTRADICT THE OFFLINE DESIGN
//
// Community Alerts is not a peer feature. It is admin-to-everyone,
// read-only for students, and it already depended on server state to be
// trusted at all — the KeyDirectory lookup IS a server dependency, just an
// indirect and fragile one. This replaces an implicit dependency with an
// explicit one and gets durability for free. Chat, vibes, tasks, study
// tags and games remain entirely on-device.
//
// DEDUPLICATION is by (senderTag, msgId) — the same pair the BLE receiver
// already keys reassembly on — so an alert that arrives by both routes
// lands once. Alerts posted when the radio send failed have no tag, and
// fall back to (author, timestamp).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One alert as the server holds it.
@immutable
class ServerCommunityAlert {
  final String id;
  final String authorUsername;
  final String? senderTag;
  final int? msgId;
  final String body;
  final DateTime createdAt;
  final DateTime? deletedAt;
  final int? deletedReason;

  const ServerCommunityAlert({
    required this.id,
    required this.authorUsername,
    required this.senderTag,
    required this.msgId,
    required this.body,
    required this.createdAt,
    required this.deletedAt,
    required this.deletedReason,
  });

  bool get isDeleted => deletedAt != null;

  /// Stable key for matching against a copy received over BLE. Prefers the
  /// wire identity; falls back to author+timestamp for an alert that never
  /// made it onto the radio.
  String get dedupKey => (senderTag != null && msgId != null)
      ? '$senderTag:$msgId'
      : '$authorUsername@${createdAt.millisecondsSinceEpoch}';
}

class CommunityAlertSync {
  CommunityAlertSync._();
  static final CommunityAlertSync instance = CommunityAlertSync._();

  /// High-water mark, so a poll asks only for what this device has not
  /// seen. Persisted because the useful case is an app that was closed
  /// while the alert was sent.
  static const _kSinceKey = 'community_alerts_since_v1';

  /// Alerts fetched but not yet merged into the feed. The Community Alerts
  /// page listens to this; keeping the fetch here rather than in the page
  /// is what lets it run while the user is nowhere near that tab.
  final ValueNotifier<List<ServerCommunityAlert>> pending =
      ValueNotifier<List<ServerCommunityAlert>>(const []);

  bool _inFlight = false;

  /// Fetches anything new. Best-effort: returns an empty list when offline,
  /// the server is unreachable, or 0024 has not been applied.
  ///
  /// Never throws. It is called from the same periodic poll as
  /// _syncIdentityStatus, and an exception there would take the identity
  /// check down with it.
  Future<List<ServerCommunityAlert>> fetch() async {
    if (_inFlight) return const [];
    _inFlight = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) return const [];

      final sinceRaw = prefs.getString(_kSinceKey);
      final rows = await Supabase.instance.client
          .rpc('list_community_alerts', params: {
        'p_hops_token': token,
        'p_since': sinceRaw,
        'p_limit': 100,
      }) as List;

      final alerts = rows
          .cast<Map<String, dynamic>>()
          .map((r) => ServerCommunityAlert(
                id: r['id'] as String? ?? '',
                authorUsername: r['author_username'] as String? ?? '(admin)',
                senderTag: r['sender_tag'] as String?,
                msgId: (r['msg_id'] as num?)?.toInt(),
                body: r['body'] as String? ?? '',
                createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
                deletedAt: r['deleted_at'] == null
                    ? null
                    : DateTime.parse(r['deleted_at'] as String).toLocal(),
                deletedReason: (r['deleted_reason'] as num?)?.toInt(),
              ))
          .toList();

      if (alerts.isNotEmpty) {
        // Advance the mark to the newest thing seen, by created_at AND
        // deleted_at: a tombstone set on an older alert is newer news than
        // that alert's own timestamp, and marking only by created_at would
        // re-fetch it forever or skip it entirely.
        var newest = DateTime.fromMillisecondsSinceEpoch(0);
        for (final a in alerts) {
          if (a.createdAt.isAfter(newest)) newest = a.createdAt;
          final d = a.deletedAt;
          if (d != null && d.isAfter(newest)) newest = d;
        }
        await prefs.setString(_kSinceKey, newest.toUtc().toIso8601String());
        pending.value = alerts;
      }
      return alerts;
    } catch (_) {
      // Offline, unreachable, or 0024 not applied. The BLE path is
      // unaffected either way, so this is genuinely a no-op rather than a
      // failure worth surfacing.
      return const [];
    } finally {
      _inFlight = false;
    }
  }

  /// Called by the page once it has merged what it was given.
  void clearPending() => pending.value = const [];

  /// Publishes an alert to the server alongside the BLE broadcast.
  ///
  /// Admin app only. Returns false on any failure — the caller should
  /// still treat the BLE send as the primary result, since an alert that
  /// went out over the radio reached everyone in range whether or not this
  /// succeeded.
  Future<bool> post({
    required String body,
    String? senderTag,
    int? msgId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) return false;
      await Supabase.instance.client.rpc('post_community_alert', params: {
        'p_hops_token': token,
        'p_body': body,
        'p_sender_tag': senderTag,
        'p_msg_id': msgId,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Mirrors a BLE withdrawal (CX:) to the server, so a device that only
  /// ever learns about this alert from the server also learns it was
  /// withdrawn.
  Future<bool> withdraw({
    required String senderTag,
    required int msgId,
    required int reason,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('saved_hops_token');
      if (token == null) return false;
      await Supabase.instance.client.rpc('delete_community_alert', params: {
        'p_hops_token': token,
        'p_sender_tag': senderTag,
        'p_msg_id': msgId,
        'p_reason': reason,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  void resetForTest() {
    pending.value = const [];
    _inFlight = false;
  }
}
