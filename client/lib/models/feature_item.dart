import 'package:flutter/material.dart';
import 'package:client/views/hops_hopper_page.dart';
import 'package:client/views/hops_wordle_page.dart';

class FeatureItem {
  final int id;
  final String name;
  final String shortDesc;
  final String longDesc;
  final IconData icon;
  final Widget Function()? pageBuilder; // optional target page

  const FeatureItem({
    required this.id,
    required this.name,
    required this.shortDesc,
    required this.longDesc,
    required this.icon,
    this.pageBuilder,
  });
}

// List of all available features (you can add more later)
//
// Not `const` — Hops Hopper/Hops Wordle below set pageBuilder to a closure,
// and a function literal is never a compile-time constant in Dart, so the
// list itself (and each FeatureItem(...) element within it) can no longer
// be const even though most entries individually still could be. `final`
// gives the same "never reassigned" guarantee this catalog actually needs.
final List<FeatureItem> allFeatures = [
  const FeatureItem(
    id: 2,
    name: "Watch Me",
    shortDesc: "Let a friend keep an eye on you while you're out alone.",
    longDesc:
    "Send a watch request to a friend, or accept one from them. Once it's on, your phones quietly track each "
    "other's Bluetooth signal — if one of you drifts out of range or disappears suddenly, the other gets an "
    "alert. Handy for a late walk home, meeting up in a crowd, or just wanting someone to know you're okay.",
    icon: Icons.visibility,
  ),
  const FeatureItem(
    id: 5,
    name: "Vibe Check",
    shortDesc: "See which spots nearby are busy before you get there.",
    longDesc:
    "Tag a location with how crowded it feels right now, and see what other Hoppers nearby have reported. "
    "Useful for finding a quiet table in the library, checking if the cafeteria line is worth it, or scouting "
    "out a spot to study before you walk all the way over.",
    icon: Icons.people_outline,
  ),
  // FeatureItem(
  //   id: 8,
  //   name: "Hops & Robbers",
  //   shortDesc: "Infection tag game – run from the Robbers!",
  //   longDesc:
  //   "One player starts as a Robber. Tag nearby Runners to turn them into Robbers. Last Runner standing wins!",
  //   icon: Icons.sports_kabaddi,
  // ),
  const FeatureItem(
    id: 9,
    name: "Task Tracker",
    shortDesc: "A to-do list and calendar that works with zero signal.",
    longDesc:
    "Jot down assignments and deadlines, set a due date, and get a reminder when it's time — everything's "
    "saved right on your device, so it works with no Wi-Fi or data at all. A built-in calendar view shows "
    "what's coming up at a glance.",
    icon: Icons.task_alt,
  ),
  const FeatureItem(
    id: 11,
    name: "Hops Share",
    shortDesc: "Send files and notes to someone nearby, no internet needed.",
    longDesc:
    "Beam a photo, PDF, or quick text note straight to a friend standing near you over Bluetooth. Perfect for "
    "passing along class notes, swapping a document, or sending a file when there's no Wi-Fi in sight.",
    icon: Icons.file_present,
  ),
  // Both games below are fully self-contained (no BLE, no injected data),
  // so — unlike Watch Me/Vibe Check/Hops Share above — they don't need a
  // case in hops_app.dart's _openFeaturePage; pageBuilder is all they need.
  FeatureItem(
    id: 12,
    name: "Hops Hopper",
    shortDesc: "Tap to flap through the gaps — how far can you get?",
    longDesc:
    "A Flappy-Bird-style flyer: tap to flap against gravity and thread the gap between each incoming pipe. "
    "Speed ramps up in levels the further you get, so it gets faster and faster the longer you last. Every 5 "
    "pipes cleared earns a carrot — Hops' in-app currency, spendable in the Hops Shop.",
    icon: Icons.directions_run,
    pageBuilder: () => const HopsHopperPage(),
  ),
  FeatureItem(
    id: 13,
    name: "Hops Wordle",
    shortDesc: "One word a day, six guesses — build a streak.",
    longDesc:
    "Guess your own 5-letter word of the day in six tries, same rules as the original: green means right "
    "letter right spot, yellow means right letter wrong spot. Everyone gets a different word each day, so "
    "telling a friend the answer won't get them an easy carrot. Solving in fewer guesses earns more carrots, "
    "and a daily streak keeps count of how many days in a row you've solved it.",
    icon: Icons.grid_on,
    pageBuilder: () => const HopsWordlePage(),
  ),
  const FeatureItem(
    id: 15,
    name: "Study Bunny Finder",
    shortDesc: "Tag what you're studying and find nearby classmates doing the same.",
    longDesc:
    "Broadcast the subject or course you're studying right now, and see who else nearby is "
    "hopping through the same material — handy for finding an impromptu study partner or "
    "group without needing to already know who's around. Tags are visible for 5 minutes and "
    "carry no sender identity, same as Vibe Check's crowd reports.",
    icon: Icons.menu_book,
  ),
  const FeatureItem(
    id: 16,
    name: "Lost & Found",
    shortDesc: "Post a lost or found item — it spreads device-to-device.",
    longDesc:
    "Lost your keys, or found someone's water bottle? Post it to the board. Unlike most "
    "features here, a post relays hop-to-hop through every nearby device that hears it "
    "(the same trick Emergency Flare uses), so it can reach beyond direct Bluetooth range — "
    "not just the people standing right next to you. Posts stay on the board for 24 hours.",
    icon: Icons.inventory_2_outlined,
  ),
  // Hops Shop is deliberately NOT in this catalog — it's not an "add it if
  // you want it" feature like everything else here. It's always reachable
  // from the Features tab's app bar instead (see hops_app.dart's
  // _buildFeaturesTab), the same way Contacts always has its notification
  // bell regardless of what's enabled.
];