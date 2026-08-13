// lib/services/key_directory.dart
//
// Local, offline-usable cache of {username: public directory entry},
// synced from Supabase's `profiles_public` view (see
// supabase/migrations/0001_lockdown_profiles.sql and
// 0004_admin_flare_support.sql — that view intentionally exposes nothing
// sensitive, just id/username/public_key/role/admin_title) whenever the
// device happens to be online. This is what lets Emergency Flare and
// Official Alert signatures be verified against someone the receiving
// device has never met, fully offline, as long as a sync happened at some
// point after that person signed up (or, for role, after it last changed).
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DirectoryEntry {
  final String publicKey;
  final String role; // 'student' | 'admin'
  final String? adminTitle;
  const DirectoryEntry({
    required this.publicKey,
    required this.role,
    this.adminTitle,
  });

  Map<String, dynamic> toJson() =>
      {'publicKey': publicKey, 'role': role, 'adminTitle': adminTitle};

  factory DirectoryEntry.fromJson(Map<String, dynamic> j) => DirectoryEntry(
        publicKey: j['publicKey'] as String,
        role: j['role'] as String? ?? 'student',
        adminTitle: j['adminTitle'] as String?,
      );
}

class KeyDirectory {
  static const _prefsKey = 'public_key_directory_v2';

  static Map<String, DirectoryEntry>? _cache;

  /// Best-effort refresh from Supabase. Safe to call often — failures
  /// (offline, unreachable) just leave whatever was cached from the last
  /// successful sync in place rather than clearing it.
  static Future<void> sync() async {
    try {
      final rows = await Supabase.instance.client
          .from('profiles_public')
          .select('username, public_key, role, admin_title');
      final map = <String, DirectoryEntry>{
        for (final row in (rows as List))
          (row as Map)['username'] as String: DirectoryEntry(
            publicKey: row['public_key'] as String,
            role: row['role'] as String? ?? 'student',
            adminTitle: row['admin_title'] as String?,
          ),
      };
      _cache = map;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        json.encode(map.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {
      // Offline or Supabase unreachable — not fatal, verification just
      // falls back to whatever's already cached (or nothing, pre-first-sync).
    }
  }

  static Future<DirectoryEntry?> entryFor(String username) async {
    await _ensureLoaded();
    return _cache?[username];
  }

  /// Emergency Flare/Official Alert's sender field is truncated to 8
  /// chars to fit the BLE advertisement budget (see hops_app.dart's
  /// _broadcastEmergencyFlare / _broadcastOfficialAlert), so a verifier
  /// can't look up the full username directly — this returns every cached
  /// identity whose own 8-char prefix matches, to try each against the
  /// signature. Collisions are possible in theory (two usernames sharing
  /// an 8-char prefix) but harmless here: verification only succeeds
  /// against the *correct* key, so an unrelated candidate with a matching
  /// prefix just fails and is skipped.
  static Future<List<MapEntry<String, DirectoryEntry>>> candidatesForTruncatedUsername(
      String truncated) async {
    await _ensureLoaded();
    final map = _cache ?? {};
    return map.entries.where((e) {
      final prefix = e.key.length > 8 ? e.key.substring(0, 8) : e.key;
      return prefix == truncated;
    }).toList();
  }

  static Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) {
      _cache = {};
      return;
    }
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _cache = decoded.map(
          (k, v) => MapEntry(k, DirectoryEntry.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      _cache = {};
    }
  }
}
