import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    },
    {
      'icon': Icons.warning_amber_rounded,
      'title': 'Emergency Flare',
      'desc': 'Long‑press the red button to alert nearby users in an emergency. They will hear a loud alarm even if their phone is on silent.',
    },
    {
      'icon': Icons.chat_bubble_outline,
      'title': 'Offline Chat',
      'desc': 'Talk to friends without internet. Messages hop directly between phones via Bluetooth.',
    },
    {
      'icon': Icons.people_outline,
      'title': 'Vibe Check',
      'desc': 'See how crowded campus spots are in real time. Share your own crowd report to help others.',
    },
    {
      'icon': Icons.shield_outlined,
      'title': 'Watch Me',
      'desc': 'Keep an eye on a friend’s safety. You’ll be alerted if their signal disappears or becomes too weak.',
    },
  ];

  void _finishWalkthrough() async {
    if (widget.showOnboarding) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('walkthrough_seen', true);
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
                  child: Column(
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
                        style: TextStyle(fontSize: 16, color: colors.onBackground.withOpacity(0.8)),
                        textAlign: TextAlign.center,
                      ),
                    ],
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