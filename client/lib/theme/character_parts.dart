// lib/theme/character_parts.dart
//
// The other two layers of the Hops Character Creator (see
// character_creator_page.dart) — base creature lives in avatar_icons.dart
// since it doubles as the thing actually rendered. Combining a base
// creature with a tint and an accessory gives real mix-and-match variety
// (6 creatures × 6 tints × 7 accessories = well over 200 combinations)
// without needing any new illustrated art — everything is either an emoji
// glyph or a flat-recolored silhouette of one, same technique
// hops_hopper_page.dart already uses for its bunny skins.
import 'package:flutter/material.dart';

class CharacterTintOption {
  final String id;
  final String label;
  final Color? color; // null = "Natural" — the emoji's own original colors
  final int? carrotCost; // null = free, always owned
  const CharacterTintOption({
    required this.id,
    required this.label,
    this.color,
    this.carrotCost,
  });
}

const String kCharacterTintDefault = 'char:tint:natural';

class CharacterTintOptions {
  static const List<CharacterTintOption> all = [
    CharacterTintOption(id: kCharacterTintDefault, label: 'Natural'),
    CharacterTintOption(id: 'char:tint:gold', label: 'Gold', color: Color(0xFFD4A017), carrotCost: 10),
    CharacterTintOption(id: 'char:tint:sky', label: 'Sky Blue', color: Color(0xFF3AA6D9), carrotCost: 10),
    CharacterTintOption(id: 'char:tint:rose', label: 'Rose', color: Color(0xFFE0567C), carrotCost: 10),
    CharacterTintOption(id: 'char:tint:mint', label: 'Mint', color: Color(0xFF3FBF8F), carrotCost: 10),
    CharacterTintOption(id: 'char:tint:shadow', label: 'Shadow', color: Color(0xFF2B2B38), carrotCost: 15),
  ];

  static CharacterTintOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

class CharacterAccessoryOption {
  final String id;
  final String label;
  final String? emoji; // null = "None"
  final int? carrotCost; // null = free, always owned
  // Where this accessory sits on the creature, as a fraction (0..1) of the
  // avatar's own width/height — (0.5, 0.5) is dead center. Different
  // accessory *kinds* wear in different places (a hat sits above the head,
  // a bow tie sits below the chin), so this is per-option rather than one
  // fixed spot for every accessory. scale is the accessory's own font size
  // as a fraction of the avatar size. Emoji art isn't on a shared template
  // across different base creatures, so these are hand-tuned approximate
  // anchors, not a pixel-perfect fit for every creature — but a bow tie
  // sitting under the chin and a hat sitting above the head reads as
  // "worn" for every base in this catalog, which a fixed corner badge
  // never did.
  final double anchorDx;
  final double anchorDy;
  final double scale;
  const CharacterAccessoryOption({
    required this.id,
    required this.label,
    this.emoji,
    this.carrotCost,
    this.anchorDx = 0.5,
    this.anchorDy = 0.5,
    this.scale = 0.34,
  });
}

const String kCharacterAccessoryDefault = 'char:acc:none';

class CharacterAccessoryOptions {
  static const List<CharacterAccessoryOption> all = [
    CharacterAccessoryOption(id: kCharacterAccessoryDefault, label: 'None'),
    CharacterAccessoryOption(
      id: 'char:acc:glasses', label: 'Sunglasses', emoji: '🕶️', carrotCost: 10,
      anchorDx: 0.5, anchorDy: 0.44, scale: 0.5,
    ),
    CharacterAccessoryOption(
      id: 'char:acc:tophat', label: 'Top Hat', emoji: '🎩', carrotCost: 15,
      anchorDx: 0.5, anchorDy: 0.1, scale: 0.5,
    ),
    CharacterAccessoryOption(
      id: 'char:acc:crown', label: 'Crown', emoji: '👑', carrotCost: 20,
      anchorDx: 0.5, anchorDy: 0.08, scale: 0.46,
    ),
    CharacterAccessoryOption(
      id: 'char:acc:bowtie', label: 'Bow Tie', emoji: '🎀', carrotCost: 10,
      anchorDx: 0.5, anchorDy: 0.8, scale: 0.34,
    ),
    CharacterAccessoryOption(
      id: 'char:acc:headphones', label: 'Headphones', emoji: '🎧', carrotCost: 15,
      anchorDx: 0.5, anchorDy: 0.22, scale: 0.62,
    ),
    CharacterAccessoryOption(
      id: 'char:acc:flower', label: 'Flower', emoji: '🌸', carrotCost: 10,
      anchorDx: 0.26, anchorDy: 0.22, scale: 0.32,
    ),
  ];

  static CharacterAccessoryOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
