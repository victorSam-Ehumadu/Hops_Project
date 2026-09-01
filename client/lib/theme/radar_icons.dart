// lib/theme/radar_icons.dart
//
// Hops Shop cosmetic: what a nearby Hopper's blip looks like on YOUR OWN
// radar (radar_screen.dart's RadarPainter). Purely a local rendering
// choice — like the AppTheme catalog, nothing here is broadcast to other
// devices, so picking "Fox" doesn't change what anyone else sees when
// THEY look at YOUR blip on their own radar. See cosmetic_prefs.dart's
// header comment for the fuller "why local-only" reasoning.
//
// `emoji == null` is the sentinel for the original plain colored dot —
// RadarPainter keeps its existing drawCircle rendering for that case
// rather than drawing a literal "no emoji" glyph.
class RadarIconOption {
  final String id;
  final String label;
  final String? emoji;
  final int? carrotCost; // null = free, always owned
  const RadarIconOption({
    required this.id,
    required this.label,
    this.emoji,
    this.carrotCost,
  });
}

const String kRadarIconDefault = 'radar:dot';

class RadarIconOptions {
  static const List<RadarIconOption> all = [
    RadarIconOption(id: kRadarIconDefault, label: 'Classic Dot'),
    RadarIconOption(id: 'radar:bunny', label: 'Bunny', emoji: '🐰', carrotCost: 15),
    RadarIconOption(id: 'radar:fox', label: 'Fox', emoji: '🦊', carrotCost: 15),
    RadarIconOption(id: 'radar:owl', label: 'Owl', emoji: '🦉', carrotCost: 15),
    RadarIconOption(id: 'radar:cat', label: 'Cat', emoji: '🐱', carrotCost: 15),
    RadarIconOption(id: 'radar:turtle', label: 'Turtle', emoji: '🐢', carrotCost: 15),
    RadarIconOption(id: 'radar:hedgehog', label: 'Hedgehog', emoji: '🦔', carrotCost: 15),
    RadarIconOption(id: 'radar:dragon', label: 'Dragon', emoji: '🐉', carrotCost: 25),
  ];

  static RadarIconOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}
