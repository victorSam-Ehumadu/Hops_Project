// lib/theme/avatar_frames.dart
//
// Hops Shop cosmetic: a decorative ring drawn around your OWN avatar
// (app bar avatar button, Profile screen). Local rendering only, same
// caveat as every other entry in this file's sibling catalogs — a frame
// isn't part of the bytes sent to a contact when your avatar photo syncs
// to them (see rfcomm_chat_service.dart's sendProfile), so friends won't
// see your frame on their end yet. See cosmetic_prefs.dart's header
// comment for the fuller reasoning.
import 'package:flutter/material.dart';

class AvatarFrameOption {
  final String id;
  final String label;
  final List<Color>? gradient; // null = no frame (plain avatar)
  final int? carrotCost; // null = free, always owned
  const AvatarFrameOption({
    required this.id,
    required this.label,
    this.gradient,
    this.carrotCost,
  });
}

const String kAvatarFrameDefault = 'frame:none';

class AvatarFrameOptions {
  static const List<AvatarFrameOption> all = [
    AvatarFrameOption(id: kAvatarFrameDefault, label: 'No Frame'),
    AvatarFrameOption(
      id: 'frame:gold',
      label: 'Gold Ring',
      gradient: [Color(0xFFF4D06F), Color(0xFFB8860B)],
      carrotCost: 20,
    ),
    AvatarFrameOption(
      id: 'frame:sunset',
      label: 'Sunset',
      gradient: [Color(0xFFFF7E5F), Color(0xFFFEB47B)],
      carrotCost: 20,
    ),
    AvatarFrameOption(
      id: 'frame:ocean',
      label: 'Ocean',
      gradient: [Color(0xFF2193B0), Color(0xFF6DD5ED)],
      carrotCost: 20,
    ),
    AvatarFrameOption(
      id: 'frame:amethyst',
      label: 'Amethyst',
      gradient: [Color(0xFF9D50BB), Color(0xFF6E48AA)],
      carrotCost: 25,
    ),
  ];

  static AvatarFrameOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

/// Wraps [child] (expected to be a CircleAvatar-sized widget of
/// [avatarDiameter]) with the selected frame's gradient ring, sized to
/// exactly enclose it. A no-op passthrough for the "No Frame" default so
/// call sites don't need their own null-check branch.
class HopsAvatarFrame extends StatelessWidget {
  final String frameId;
  final double avatarDiameter;
  final Widget child;

  const HopsAvatarFrame({
    super.key,
    required this.frameId,
    required this.avatarDiameter,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final frame = AvatarFrameOptions.byId(frameId);
    if (frame.gradient == null) return child;
    const ringThickness = 3.0;
    return Container(
      width: avatarDiameter + ringThickness * 2,
      height: avatarDiameter + ringThickness * 2,
      padding: const EdgeInsets.all(ringThickness),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: frame.gradient!,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: child,
    );
  }
}
