// lib/theme/username_flairs.dart
//
// Hops Shop cosmetic: a small emoji badge shown next to your own name
// (Profile screen, app bar). Local rendering only — see
// cosmetic_prefs.dart's header comment; a flair doesn't ride along with
// anything sent to contacts, so it's own-device only, same as radar
// icons/Hopper skins/chat bubble skins/Wordle palettes.
class FlairOption {
  final String id;
  final String label;
  final String? emoji; // null = no flair
  final int? carrotCost; // null = free, always owned
  const FlairOption({
    required this.id,
    required this.label,
    this.emoji,
    this.carrotCost,
  });
}

const String kFlairDefault = 'flair:none';

class FlairOptions {
  static const List<FlairOption> all = [
    FlairOption(id: kFlairDefault, label: 'No Flair'),
    FlairOption(id: 'flair:star', label: 'Star', emoji: '⭐', carrotCost: 10),
    FlairOption(id: 'flair:fire', label: 'Fire', emoji: '🔥', carrotCost: 10),
    FlairOption(id: 'flair:sparkle', label: 'Sparkle', emoji: '✨', carrotCost: 10),
    FlairOption(id: 'flair:crown', label: 'Crown', emoji: '👑', carrotCost: 20),
    FlairOption(id: 'flair:carrot', label: 'Carrot', emoji: '🥕', carrotCost: 10),
  ];

  static FlairOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
