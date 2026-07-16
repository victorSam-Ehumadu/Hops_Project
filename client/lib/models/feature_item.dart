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
];