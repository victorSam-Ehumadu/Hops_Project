import 'dart:math';
import 'package:flutter/material.dart';

// Simple tap-to-flip 3D card, shared by the pre-signup info page
// (auth_screen.dart's 4 bento cards) and the post-signup onboarding
// walkthrough (walkthrough_screen.dart) — front shows the short version,
// back shows more detail for whoever taps it. No animation package needed:
// a single AnimationController driving a Y-axis rotation, swapping which
// child is drawn at the halfway point (90°) so nothing ever renders
// mirror-flipped.
class HopsFlipCard extends StatefulWidget {
  final Widget front;
  final Widget back;
  const HopsFlipCard({super.key, required this.front, required this.back});

  @override
  State<HopsFlipCard> createState() => _HopsFlipCardState();
}

class _HopsFlipCardState extends State<HopsFlipCard> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  bool _showingFront = true;

  void _toggle() {
    if (_showingFront) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    setState(() => _showingFront = !_showingFront);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final angle = _controller.value * pi;
          final isShowingBack = angle > pi / 2;
          // Once past the halfway point, swap in the back content and
          // "unmirror" it by subtracting pi — otherwise the back side
          // would render as backwards text sliding in from the right.
          final displayAngle = isShowingBack ? angle - pi : angle;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015) // perspective
              ..rotateY(displayAngle),
            child: isShowingBack ? widget.back : widget.front,
          );
        },
      ),
    );
  }
}
