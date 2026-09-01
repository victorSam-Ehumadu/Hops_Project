// lib/theme/hopper_skins.dart
//
// Hops Shop cosmetic: what color the Hops Hopper bunny is tinted. The
// default entry (color: null) means "adaptive" — hops_hopper_page.dart
// falls back to ColorFiltered-tinting the sprite to colors.onSurface,
// which is what fixed the dark-theme-invisible-bunny bug in the first
// place. Every other entry is a fixed color the player picked on
// purpose, so it stays that color across light/dark themes rather than
// re-adapting.
import 'package:flutter/material.dart';

class HopperSkinOption {
  final String id;
  final String label;
  final Color? color; // null = adaptive default (colors.onSurface)
  final int? carrotCost; // null = free, always owned
  const HopperSkinOption({
    required this.id,
    required this.label,
    this.color,
    this.carrotCost,
  });
}

const String kHopperSkinDefault = 'hopper:default';

class HopperSkinOptions {
  static const List<HopperSkinOption> all = [
    HopperSkinOption(id: kHopperSkinDefault, label: 'Default'),
    HopperSkinOption(id: 'hopper:gold', label: 'Gold', color: Color(0xFFD4A017), carrotCost: 15),
    HopperSkinOption(id: 'hopper:sky', label: 'Sky Blue', color: Color(0xFF3AA6D9), carrotCost: 15),
    HopperSkinOption(id: 'hopper:rose', label: 'Rose', color: Color(0xFFE0567C), carrotCost: 15),
    HopperSkinOption(id: 'hopper:mint', label: 'Mint', color: Color(0xFF3FBF8F), carrotCost: 15),
    HopperSkinOption(id: 'hopper:shadow', label: 'Shadow', color: Color(0xFF2B2B38), carrotCost: 20),
  ];

  static HopperSkinOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
