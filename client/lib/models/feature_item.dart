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
    id: 1,
    name: "Emergency Flare",
    shortDesc: "Send a distress signal to nearby Hops users.",
    longDesc:
    "When activated, your device broadcasts a special emergency beacon that all nearby Hops users will see. Use in case of danger.",
    icon: Icons.warning_amber_rounded,
    // pageBuilder: () => EmergencyFlarePage(),   // example when you build it
  ),
  FeatureItem(
    id: 2,
    name: "Watch Me",
    shortDesc: "Buddy safety tether with signal strength monitoring.",
    longDesc:
    "Pair with a trusted friend. If their signal drops below a threshold or vanishes, your phone will alert you.",
    icon: Icons.visibility,
  ),
  FeatureItem(
    id: 3,
    name: "Dead Drop Notes",
    shortDesc: "Leave digital post-its at GPS locations.",
    longDesc:
    "Drop notes at specific campus spots. Other Hops users see them when they pass by.",
    icon: Icons.note_add,
  ),
  FeatureItem(
    id: 4,
    name: "Campus Bulletin",
    shortDesc: "Decentralized notice board for lectures/events.",
    longDesc:
    "Posts are stored and forwarded across the mesh. Great for lecture changes or campus events.",
    icon: Icons.dashboard,
  ),
  FeatureItem(
    id: 5,
    name: "Vibe Check",
    shortDesc: "Real-time crowd density heatmap.",
    longDesc:
    "Shows how crowded areas are based on the number of BLE devices detected. Helps you find quiet spots.",
    icon: Icons.people_outline,
  ),
  FeatureItem(
    id: 6,
    name: "Study Share",
    shortDesc: "Share lecture notes peer-to-peer.",
    longDesc:
    "Send PDFs, images, or text notes directly to classmates without internet. Just tap their name on the radar.",
    icon: Icons.menu_book,
  ),
  FeatureItem(
    id: 7,
    name: "Campus Polls",
    shortDesc: "Run live anonymous polls in class.",
    longDesc:
    "Create a poll and nearby students can vote. Results update in real time via BLE.",
    icon: Icons.poll,
  ),
  FeatureItem(
    id: 8,
    name: "Hops & Robbers",
    shortDesc: "Infection tag game – run from the Robbers!",
    longDesc:
    "One player starts as a Robber. Tag nearby Runners to turn them into Robbers. Last Runner standing wins!",
    icon: Icons.sports_kabaddi,
  ),
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