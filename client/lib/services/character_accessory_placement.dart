// lib/services/character_accessory_placement.dart
//
// Per-accessory custom placement for the Character Creator
// (character_creator_page.dart) — lets a user drag an equipped accessory
// around and pinch it to resize, instead of being stuck with
// character_parts.dart's built-in anchorDx/anchorDy/scale for that
// accessory. Keyed by accessory id (not just "the current one"), so
// switching from, say, Top Hat to Sunglasses and back doesn't lose either
// one's custom spot.
//
// A user who's never touched an accessory simply has no entry here — the
// renderer falls back to CharacterAccessoryOption's own built-in anchor in
// that case, so this only ever OVERRIDES, never replaces, the base catalog.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccessoryPlacement {
  final double dx; // 0..1, fraction of the avatar's own width
  final double dy; // 0..1, fraction of the avatar's own height
  final double scale; // the accessory's own font size, as a fraction of avatar size
  const AccessoryPlacement({required this.dx, required this.dy, required this.scale});

  Map<String, dynamic> toJson() => {'dx': dx, 'dy': dy, 'scale': scale};

  factory AccessoryPlacement.fromJson(Map<String, dynamic> json) => AccessoryPlacement(
        dx: (json['dx'] as num).toDouble(),
        dy: (json['dy'] as num).toDouble(),
        scale: (json['scale'] as num).toDouble(),
      );
}

class CharacterAccessoryPlacements {
  CharacterAccessoryPlacements._();
  static final CharacterAccessoryPlacements instance = CharacterAccessoryPlacements._();

  static const _prefsKey = 'cosmetic_char_accessory_placements_v1';

  // Keeps a resize gesture from either vanishing to a pinpoint or ballooning
  // past the avatar's own canvas.
  static const double minScale = 0.16;
  static const double maxScale = 0.72;
  // Keeps the accessory's own center from being dragged so far off the
  // avatar that it's effectively invisible/unrecoverable without a reset.
  static const double minPos = 0.04;
  static const double maxPos = 0.96;

  // Ticks on any placement change — callers (the live preview, the PNG
  // renderer) just re-read get() when this fires, the same "cheap blanket
  // rebuild" tradeoff CosmeticPrefs' ValueNotifier<String> fields already
  // make everywhere else in this app.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<String, AccessoryPlacement> _overrides = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      for (final entry in map.entries) {
        _overrides[entry.key] = AccessoryPlacement.fromJson(entry.value as Map<String, dynamic>);
      }
      revision.value++;
    } catch (_) {
      // Corrupt/older-shape entry — start clean rather than crash the
      // Character Creator.
    }
  }

  /// The user's custom placement for [accessoryId], or null if they've
  /// never moved this one — callers fall back to
  /// CharacterAccessoryOption.anchorDx/anchorDy/scale in that case.
  AccessoryPlacement? get(String accessoryId) => _overrides[accessoryId];

  Future<void> set(String accessoryId, AccessoryPlacement placement) async {
    _overrides[accessoryId] = AccessoryPlacement(
      dx: placement.dx.clamp(minPos, maxPos),
      dy: placement.dy.clamp(minPos, maxPos),
      scale: placement.scale.clamp(minScale, maxScale),
    );
    revision.value++;
    await _persist();
  }

  Future<void> reset(String accessoryId) async {
    if (_overrides.remove(accessoryId) == null) return;
    revision.value++;
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      json.encode(_overrides.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }
}
