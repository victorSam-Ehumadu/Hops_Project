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
    shortDesc: "Buddy safety tether with signal strength monitoring.",
    longDesc:
    "Pair with a trusted friend. If their signal drops below a threshold or vanishes, your phone will alert you.",
    icon: Icons.visibility,
  ),
  FeatureItem(
    id: 5,
    name: "Vibe Check",
    shortDesc: "Real-time crowd density heatmap.",
    longDesc:
    "Shows how crowded areas are based on the number of BLE devices detected. Helps you find quiet spots.",
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
    shortDesc: "Offline task list with reminders and calendar.",
    longDesc:
    "Create tasks, set due dates, and get reminders – all offline. A simple calendar view helps you stay organized.",
    icon: Icons.task_alt,
  ),
  FeatureItem(
    id: 11,
    name: "Hops Share",
    shortDesc: "Share files and notes with friends offline.",
    longDesc:
    "Send PDFs, images, or quick text notes directly to a friend over Bluetooth – no internet needed.",
    icon: Icons.file_present,
  ),
];