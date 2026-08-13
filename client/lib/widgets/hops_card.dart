// lib/widgets/hops_card.dart
//
// Shared "Elevated Soft UI" building blocks — a soft, layered shadow and a
// solid theme-aware background instead of the flat opacity-tinted
// Card/Container patterns that used to be hand-rolled slightly differently
// on every single screen. The goal is consistency: the same card language
// everywhere, not a prettier one-off per screen.
import 'package:flutter/material.dart';

class HopsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;
  final VoidCallback? onTap;

  const HopsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.radius = 20,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          // Two stacked shadows — one soft/wide for the "lifted off the
          // page" feel, one tight/subtle for a bit of grounding contact
          // right at the edge. A single big shadow alone tends to look
          // either too flat or too smudgy.
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return card;
    return HopsTapScale(onTap: onTap!, child: card);
  }
}

/// Press-down-to-shrink, release-to-spring-back micro-interaction. Cheap
/// and reusable — applied to cards/tiles across the app so tapping
/// something gives tactile feedback beyond Material's default ripple alone.
class HopsTapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const HopsTapScale({super.key, required this.child, required this.onTap});

  @override
  State<HopsTapScale> createState() => _HopsTapScaleState();
}

class _HopsTapScaleState extends State<HopsTapScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
