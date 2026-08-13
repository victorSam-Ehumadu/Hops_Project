// lib/widgets/hops_background_pattern.dart
//
// A subtle, code-drawn "hop trail" texture — paired dots suggesting
// scattered footprints, tying into the bunny/hop branding already
// established (default avatar, app logo icon). No image assets, so it
// costs nothing to ship and scales to any screen size, and it's derived
// from the active theme's primary color so it shifts automatically across
// all 10 themes rather than needing its own palette.
//
// Deliberately very low opacity — this is meant to break up flat color
// behind content, not compete with it for attention.
import 'package:flutter/material.dart';

class HopsBackgroundPattern extends StatelessWidget {
  final Widget child;
  const HopsBackgroundPattern({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _HopTrailPainter(color: colors.primary),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _HopTrailPainter extends CustomPainter {
  final Color color;
  const _HopTrailPainter({required this.color});

  static const double _spacing = 56;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withOpacity(0.05);
    // A grid of paired dots (like a little footprint), staggered every
    // other row so it reads as scattered rather than a rigid lattice.
    for (double y = -_spacing; y < size.height + _spacing; y += _spacing) {
      final rowIndex = (y / _spacing).round();
      final xOffset = rowIndex.isOdd ? _spacing / 2 : 0.0;
      for (double x = -_spacing; x < size.width + _spacing; x += _spacing) {
        final cx = x + xOffset;
        canvas.drawCircle(Offset(cx - 4, y), 2.2, paint);
        canvas.drawCircle(Offset(cx + 4, y + 5), 2.2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HopTrailPainter oldDelegate) => oldDelegate.color != color;
}
