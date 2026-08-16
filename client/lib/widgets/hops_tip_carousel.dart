// hops_tip_carousel.dart
//
// Replaces the Home tab's old quick-action shortcut row (Community / My
// Features / Add Contact — removed because they duplicated the bottom nav
// and the "+" FAB one tap away) with a rotating strip of fun facts and
// usage tips about the app. Cycles on its own every 2 minutes, or
// immediately when tapped — deliberately styled to read as a passive
// caption, not a button (no shadow, no border, no fill), so it doesn't
// compete with actual controls on the page.
import 'dart:async';
import 'package:flutter/material.dart';

const List<_HopsTip> _tips = [
  _HopsTip(Icons.wifi_off_rounded, "Hops works entirely offline — no signal, no problem. Everything runs over Bluetooth."),
  _HopsTip(Icons.touch_app_outlined, "See a dot on the radar? Tap it to send that person a friend request."),
  _HopsTip(Icons.visibility, "Turn on Discoverable (top-right of the radar) so friends can see your name and quick-add you — off by default, and always your choice."),
  _HopsTip(Icons.qr_code_2, "In a hurry? Generate a pairing code and let a friend scan it instead of typing — or flip it to a QR code."),
  _HopsTip(Icons.shield_outlined, "Your chats are only ever exchanged directly, device-to-device — never through a server."),
  _HopsTip(Icons.visibility_off_outlined, "Strangers show up as anonymous dots on radar until you've chatted, sent a friend request, or set up Watch Me — that's on purpose."),
  _HopsTip(Icons.campaign_outlined, "Community Chat broadcasts to every nearby Hopper at once — perfect for group meetups."),
  _HopsTip(Icons.bolt_outlined, "The Emergency Flare alerts everyone in Bluetooth range, and even relays through their phones to reach further."),
  _HopsTip(Icons.star_outline, "Long-press any tile in My Features to pin your favorites to the top."),
  _HopsTip(Icons.groups_outlined, "Watch Me lets a buddy keep an eye on your distance from them in real time."),
  _HopsTip(Icons.palette_outlined, "Not feeling this look? Head to Customize Hops to change the color theme and font."),
  _HopsTip(Icons.keyboard_arrow_down, "Swipe down on the bottom nav bar to hide it — tap the little arrow (or swipe up) to bring it back."),
  _HopsTip(Icons.account_circle_outlined, "Tap a friend's profile picture — in a chat or on Home — to view their profile."),
  _HopsTip(Icons.swipe_outlined, "You can swipe left and right between Home, Contacts, Community, Features, and My Features — no need to tap the nav bar every time."),
  _HopsTip(Icons.sync_alt_outlined, "Your Bluetooth name quietly rotates every 15 minutes — like Apple/Google's exposure notifications — so no one can track your phone by broadcast name alone."),
  _HopsTip(Icons.key_outlined, "Each device has its own private key generated at sign-up, kept only on that device — it's what lets Hops verify an Emergency Flare or Official Alert really came from who it says."),
  _HopsTip(Icons.lock_outline, "Changing your password or deleting your account both re-check your current password server-side first — a stolen session token alone isn't enough."),
  _HopsTip(Icons.event_note_outlined, "Task Tracker has a built-in calendar — tap a date to see (or add) everything due that day."),
  _HopsTip(Icons.send_outlined, "Sending a file in Hops Share now shows a live progress bar, so you know it's actually moving."),
  _HopsTip(Icons.verified_user_outlined, "Official Alerts (the admin-only red tier) are cryptographically signed — a spoofed one gets rejected instead of just labeled \"unverified.\""),
];

class _HopsTip {
  final IconData icon;
  final String text;
  const _HopsTip(this.icon, this.text);
}

class HopsTipCarousel extends StatefulWidget {
  const HopsTipCarousel({super.key});

  @override
  State<HopsTipCarousel> createState() => _HopsTipCarouselState();
}

class _HopsTipCarouselState extends State<HopsTipCarousel> {
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Start on a random tip so the same one doesn't always greet the user
    // first thing every single app open.
    _index = DateTime.now().millisecondsSinceEpoch % _tips.length;
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _advance());
  }

  void _advance() {
    if (!mounted) return;
    setState(() => _index = (_index + 1) % _tips.length);
  }

  void _onTap() {
    _advance();
    _startTimer(); // tapping counts as "seen" — push the auto-cycle back out
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tip = _tips[_index];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
                  .animate(animation),
              child: child,
            ),
          ),
          child: Row(
            key: ValueKey(_index),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(tip.icon, size: 16, color: colors.primary.withValues(alpha: 0.6)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tip.text,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    fontStyle: FontStyle.italic,
                    color: colors.onSurface.withValues(alpha: 0.55),
                  ),
                  // Several of the longer tips (security/privacy ones
                  // especially) didn't actually fit in 2 lines at this font
                  // size and were rendering as a truncated "…" instead of
                  // real text — 3 lines gives them enough room. See
                  // radar_screen.dart's _kTipCarouselHeight, which reserves
                  // layout space to match.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
