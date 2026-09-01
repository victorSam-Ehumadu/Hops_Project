// lib/widgets/thought_bubble.dart
//
// A thought-bubble-style callout — two small trailing dots growing toward
// the main bubble, cloud-thought style rather than a speech-bubble's
// triangular tail. Shows a user's "thinking" status (see
// edit_identity_screen.dart's thinking_status field) next to their avatar,
// both on your own Profile screen and a contact's Contact Profile screen
// (once it's synced to them — see hops_chat_service.dart's sendProfile).
import 'package:flutter/material.dart';

class ThoughtBubble extends StatelessWidget {
  final String text;
  const ThoughtBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Fixed dark bubble regardless of theme — reads as its own distinct
    // "speech" surface floating over whatever's behind it (banner or
    // background), the same design language a chat bubble uses rather
    // than blending into the page.
    const bg = Color(0xF0202020);
    const fg = Colors.white;
    return SizedBox(
      width: 96,
      height: 64,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 20,
            child: Container(width: 7, height: 7, decoration: const BoxDecoration(color: bg, shape: BoxShape.circle)),
          ),
          Positioned(
            left: 10,
            top: 8,
            child: Container(width: 13, height: 13, decoration: const BoxDecoration(color: bg, shape: BoxShape.circle)),
          ),
          Positioned(
            left: 24,
            top: -8,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 130),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: colors.shadow.withValues(alpha: 0.25), blurRadius: 6, offset: const Offset(0, 2))],
              ),
              child: Text(
                text,
                style: const TextStyle(color: fg, fontSize: 12.5, height: 1.25),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
