// lib/widgets/hops_bot_avatar.dart
//
// The assistant's mark, used everywhere Hops appears as a contact.
//
// It exists because the bot previously wore the same Icons.cruelty_free
// glyph every other contact falls back to when they have no photo — so the
// one entry in the list that isn't a person looked exactly like the people.
// This is deliberately unmistakable at a glance: a filled gradient disc
// (everyone else's fallback is a faint tinted circle), the actual Hops
// bunny artwork rather than a stock Material icon, a soft glow, and a
// small always-on dot where a person's presence indicator would be.
//
// Drawn from theme colours so it stays right across the whole theme
// catalog, and sized from one parameter so the contacts row (24) and the
// chat app bar (16) stay visually consistent.
import 'package:flutter/material.dart';

class HopsBotAvatar extends StatelessWidget {
  /// Radius, matching CircleAvatar's own parameter so this drops straight
  /// into the places that used one.
  final double radius;

  /// The little corner dot. Off in tight spots (the app bar) where it'd be
  /// more speck than signal.
  final bool showStatusDot;

  const HopsBotAvatar({
    super.key,
    this.radius = 24,
    this.showStatusDot = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = radius * 2;
    final dotSize = (radius * 0.34).clamp(7.0, 13.0);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Diagonal rather than flat fill — the one contact that
              // catches the light differently is the one you spot without
              // reading anything.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.primary,
                  Color.lerp(colors.primary, colors.tertiary, 0.55) ??
                      colors.primary,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.primary.withValues(alpha: 0.35),
                  blurRadius: radius * 0.5,
                  spreadRadius: radius * 0.04,
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.all(radius * 0.28),
              child: Image.asset(
                'assets/images/hops_bunny.png',
                fit: BoxFit.contain,
                // Knocked out to white against the gradient. The source is
                // near-black line art (average RGB ~30), so without this
                // it's a dark smudge on a saturated disc; srcIn keeps the
                // silhouette and soft edges while replacing the colour.
                color: Colors.white,
                colorBlendMode: BlendMode.srcIn,
                // Real fallback, not decoration — this widget renders on
                // the Contacts tab and in the chat app bar, and neither
                // should be able to throw over a missing asset.
                errorBuilder: (_, __, ___) => Icon(
                  Icons.cruelty_free,
                  size: radius * 1.1,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          if (showStatusDot)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.lightGreenAccent.shade700,
                  // Ring in the surface colour so the dot reads as sitting
                  // on top of the disc rather than being part of it.
                  border: Border.all(color: colors.surface, width: dotSize * 0.18),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
