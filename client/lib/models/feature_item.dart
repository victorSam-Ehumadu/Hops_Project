import 'package:flutter/material.dart';

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
const List<FeatureItem> allFeatures = [
  FeatureItem(
    id: 2,
    name: "Watch Me",
    shortDesc: "Let a friend keep an eye on you while you're out alone.",
    longDesc:
    "Send a watch request to a friend, or accept one from them. Once it's on, your phones quietly track each "
    "other's Bluetooth signal — if one of you drifts out of range or disappears suddenly, the other gets an "
    "alert. Handy for a late walk home, meeting up in a crowd, or just wanting someone to know you're okay.",
    icon: Icons.visibility,
  ),
  FeatureItem(
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
  FeatureItem(
    id: 9,
    name: "Task Tracker",
    shortDesc: "A to-do list and calendar that works with zero signal.",
    longDesc:
    "Jot down assignments and deadlines, set a due date, and get a reminder when it's time — everything's "
    "saved right on your device, so it works with no Wi-Fi or data at all. A built-in calendar view shows "
    "what's coming up at a glance.",
    icon: Icons.task_alt,
  ),
  FeatureItem(
    id: 11,
    name: "Hops Share",
    shortDesc: "Send files and notes to someone nearby, no internet needed.",
    longDesc:
    "Beam a photo, PDF, or quick text note straight to a friend standing near you over Bluetooth. Perfect for "
    "passing along class notes, swapping a document, or sending a file when there's no Wi-Fi in sight.",
    icon: Icons.file_present,
  ),
];