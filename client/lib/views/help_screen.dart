// lib/views/help_screen.dart
//
// Help & Walkthrough — one entry point again. This was briefly split into
// two separate Settings rows (Help vs. Walkthrough) on the theory that
// "replay the tour" and "I have a question" are different intents; in
// practice that just made two things to find instead of one, so they're
// back under a single label — a FAQ first (answers most questions with
// zero waiting), a "Replay the Walkthrough" action right alongside it, and
// a contact-Hops fallback for anyone the FAQ didn't help.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/views/walkthrough_screen.dart';

const String kHopsSupportEmail = 'Hops@hoppermail.com';

class _FaqEntry {
  final String question;
  final String answer;
  const _FaqEntry(this.question, this.answer);
}

const List<_FaqEntry> _kFaqEntries = [
  _FaqEntry(
    'Why does Hops need Bluetooth turned on?',
    "Hops works without internet or signal — Radar, chat, friend requests, Emergency Flare, "
        "and most other features all run over Bluetooth Low Energy directly between nearby "
        "phones. Without Bluetooth on (and its permissions granted), none of that can see or "
        "be seen by anyone else nearby.",
  ),
  _FaqEntry(
    "Why can't I see someone I know is standing right next to me?",
    "A few common causes: they have Hops closed in the background on a phone that's "
        "aggressively battery-optimized (some Android skins kill background BLE scanning), "
        "Bluetooth permissions were denied on one of the two phones, or you're just far enough "
        "apart / behind enough walls that the signal isn't reaching. Try opening the app on "
        "both phones and standing closer together.",
  ),
  _FaqEntry(
    'Why did my message take a while to arrive, or not arrive at all?',
    "There's no server relaying messages — everything moves directly over Bluetooth between "
        "phones that are actually in range at the time. If either of you steps out of range, or "
        "the connection drops, a message can be delayed or lost. This is inherent to how an "
        "offline, no-signal-needed app works, not a bug to report.",
  ),
  _FaqEntry(
    'What does Emergency Flare actually do?',
    "It broadcasts an alert to every Hops user within Bluetooth range (and one hop further, "
        "relayed device-to-device), so people nearby know you need help. It is not a "
        "replacement for calling police, fire, or an ambulance — always contact official "
        "emergency services directly for anything serious.",
  ),
  _FaqEntry(
    'How do carrots and the Hops Shop work?',
    "Carrots are Hops' in-app currency, earned by playing Hops Hopper and Hops Wordle. Spend "
        "them in the Hops Shop on cosmetics — themes, avatar frames, radar icons, profile "
        "banners, and more. Nothing in the Shop is required to use any safety or "
        "communication feature.",
  ),
  _FaqEntry(
    "Why doesn't my Character Avatar / banner show up for my friend?",
    "Most Shop cosmetics (radar icons, Hopper skins, chat bubbles, profile banners, and so on) "
        "are your-own-device-only — they change how things look on your screen, not anyone "
        "else's. Your Character Avatar is the one exception: it becomes your real avatar photo, "
        "so it does reach contacts the same way an uploaded photo would.",
  ),
];

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  Future<void> _contactSupport(BuildContext context) async {
    final uri = Uri(
      scheme: 'mailto',
      path: kHopsSupportEmail,
      queryParameters: {'subject': 'Hops Support'},
    );
    try {
      final opened = await launchUrl(uri);
      if (opened) return;
    } catch (_) {
      // Falls through to the clipboard fallback below.
    }
    // No mail app configured (common on a bare test device/emulator) —
    // copying the address is still a usable path to actually reaching us.
    await Clipboard.setData(const ClipboardData(text: kHopsSupportEmail));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No mail app found — email address copied instead.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Help & Walkthrough', style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: HopsBackgroundPattern(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.explore_outlined, color: colors.primary, size: 22),
                      const SizedBox(width: 10),
                      Text('New here, or want a refresher?',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Replay the welcome tour of Hops' features.",
                    style: TextStyle(fontSize: 12.5, color: colors.onSurface.withValues(alpha: 0.65)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const WalkthroughScreen()),
                      ),
                      icon: const Icon(Icons.explore_outlined),
                      label: const Text('Replay the Walkthrough'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.quiz_outlined, color: colors.primary, size: 22),
                      const SizedBox(width: 10),
                      Text('Frequently Asked Questions',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: colors.primary)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "Most questions about how Hops behaves are answered here.",
                    style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < _kFaqEntries.length; i++) ...[
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        title: Text(
                          _kFaqEntries[i].question,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _kFaqEntries[i].answer,
                            style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.onSurface.withValues(alpha: 0.75)),
                          ),
                        ],
                      ),
                    ),
                    if (i < _kFaqEntries.length - 1)
                      Divider(height: 1, color: colors.onSurface.withValues(alpha: 0.08)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.mail_outline, color: colors.primary, size: 22),
                      const SizedBox(width: 10),
                      Text('Still need help?',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "If none of the above covers it, reach the Hops team directly.",
                    style: TextStyle(fontSize: 12.5, color: colors.onSurface.withValues(alpha: 0.65)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => _contactSupport(context),
                      icon: const Icon(Icons.email_outlined),
                      label: const Text('Email $kHopsSupportEmail'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
