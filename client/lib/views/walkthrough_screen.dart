import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/widgets/hops_flip_card.dart';

class WalkthroughScreen extends StatefulWidget {
  final bool showOnboarding; // if true, sets the 'seen' flag after finish
  const WalkthroughScreen({super.key, this.showOnboarding = false});

  @override
  State<WalkthroughScreen> createState() => _WalkthroughScreenState();
}

class _WalkthroughScreenState extends State<WalkthroughScreen> {
  final PageController _controller = PageController();
  int _currentPage = 0;

  final List<Map<String, dynamic>> _pages = [
    {
      'icon': Icons.radar,
      'title': 'Discover Nearby Users',
      'desc': 'The Radar shows everyone running Hops around you. Tap a dot to send a friend request.',
      'detail': 'Only devices with Hops open and Bluetooth on show up. Turn on "Discoverable" from the Radar screen if you want others to see your username on their dot before adding you.',
    },
    {
      'icon': Icons.warning_amber_rounded,
      'title': 'Emergency Flare',
      'desc': 'Long‑press the red button to alert nearby users in an emergency. They will hear a loud alarm even if their phone is on silent.',
      'detail': 'The alert lasts 30 seconds and every nearby device that hears it relays it onward for a few more seconds, so it can reach people further away than your own Bluetooth range. Hit Cancel right away if it was triggered by mistake.',
    },
    {
      'icon': Icons.chat_bubble_outline,
      'title': 'Offline Chat',
      'desc': 'Talk to friends without internet. Messages hop directly between phones via Bluetooth.',
      'detail': 'No prior pairing needed — share a 6-character code from "Add Contact," or use Discoverable mode so a friend can add you straight from your dot on the Radar.',
    },
    {
      'icon': Icons.people_outline,
      'title': 'Vibe Check',
      'desc': 'See how crowded campus spots are in real time. Share your own crowd report to help others.',
      'detail': 'Reports are anonymous and expire on their own after a while, so the crowd read always reflects what\'s happening right now rather than piling up old reports.',
    },
    {
      'icon': Icons.shield_outlined,
      'title': 'Watch Me',
      'desc': 'Keep an eye on a friend’s safety. You’ll be alerted if their signal disappears or becomes too weak.',
      'detail': 'Handy for walking somewhere alone — once your buddy accepts the request, you get notified automatically if their signal drops or goes quiet for too long. They don\'t have to do anything else once they\'ve accepted.',
    },
  ];

  void _finishWalkthrough() async {
    if (widget.showOnboarding) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('walkthrough_seen', true);
      // Consumed once by HopsApp right after this first-time walkthrough
      // to show a "you can replay this from Profile > Help" hint — the
      // Help tile's own subtitle only helps once someone's already found
      // Profile, which apparently wasn't happening on its own.
      await prefs.setBool('pending_help_hint', true);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isLast = _currentPage == _pages.length - 1;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [
          TextButton(
            onPressed: _finishWalkthrough,
            child: const Text('Skip'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (index) => setState(() => _currentPage = index),
              itemBuilder: (context, index) {
                final page = _pages[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: HopsFlipCard(
                    // Resets the flip state whenever the page itself
                    // changes, rather than carrying "flipped" over from
                    // whatever card was showing before — swiping to the
                    // next topic should always start front-side-up.
                    key: ValueKey(index),
                    front: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(page['icon'] as IconData, size: 100, color: colors.primary),
                        const SizedBox(height: 32),
                        Text(
                          page['title'] as String,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: colors.primary),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          page['desc'] as String,
                          style: TextStyle(fontSize: 16, color: colors.onSurface.withValues(alpha: 0.8)),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flip, size: 14, color: colors.primary.withValues(alpha: 0.6)),
                            const SizedBox(width: 6),
                            Text(
                              "Tap card for more",
                              style: TextStyle(fontSize: 12, color: colors.primary.withValues(alpha: 0.6), fontStyle: FontStyle.italic),
                            ),
                          ],
                        ),
                      ],
                    ),
                    back: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.info_outline, size: 40, color: colors.primary),
                          const SizedBox(height: 20),
                          Text(
                            page['title'] as String,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colors.primary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          Text(
                            page['detail'] as String,
                            style: TextStyle(fontSize: 14, height: 1.4, color: colors.onSurface.withValues(alpha: 0.85)),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.flip, size: 14, color: colors.primary.withValues(alpha: 0.6)),
                              const SizedBox(width: 6),
                              Text(
                                "Tap to flip back",
                                style: TextStyle(fontSize: 12, color: colors.primary.withValues(alpha: 0.6), fontStyle: FontStyle.italic),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 40, left: 32, right: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // dots indicator
                Row(
                  children: List.generate(_pages.length, (index) {
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _currentPage == index ? colors.primary : colors.surfaceContainerHighest,
                      ),
                    );
                  }),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
                  ),
                  onPressed: () {
                    if (isLast) {
                      _finishWalkthrough();
                    } else {
                      _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
                    }
                  },
                  child: Text(isLast ? 'Get Started' : 'Next'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
