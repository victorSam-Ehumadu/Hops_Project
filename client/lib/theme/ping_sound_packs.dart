// lib/theme/ping_sound_packs.dart
//
// Hops Shop cosmetic: which sound plays for routine notifications (friend
// requests, messages, watch-me activity — the "general_activity" channel
// in notification_service.dart). Deliberately does NOT touch Emergency
// Flare/Official Alert — those stay the same siren for everyone, on
// purpose, so an emergency never sounds different because of someone's
// shop purchase.
//
// All four tones are short, original sine-wave synthesized clips (no
// licensed/sourced audio), generated once and checked in as
// assets/sounds/ping_*.wav.
//
// IMPORTANT limitation: Android notification channels are immutable once
// created — you can't change an existing channel's sound after the fact,
// only pick a sound when a NEW channel is first created. Actually
// swapping the SYSTEM notification's sound per user would mean creating
// one Android channel per sound pack up front (and shipping the tones as
// native res/raw/ resources, not Flutter assets). That's a bigger native
// change than this pass makes. Instead, selected sounds play via
// just_audio as a one-shot local playback WHEN THE APP IS IN THE
// FOREGROUND at the moment the notification fires — same
// "custom-sound-with-a-system-fallback" pattern notification_service.dart
// already uses for the Emergency Flare siren. If Hops is backgrounded or
// closed, the notification still fires, just with the phone's normal
// default sound instead of the picked pack. Worth flagging honestly
// rather than pretending this is a full system-level override.
import 'package:flutter/material.dart';

class PingSoundOption {
  final String id;
  final String label;
  final String? asset; // null = system default (no custom playback)
  final int? carrotCost; // null = free, always owned
  const PingSoundOption({
    required this.id,
    required this.label,
    this.asset,
    this.carrotCost,
  });
}

const String kPingSoundDefault = 'sound:default';

class PingSoundOptions {
  static const List<PingSoundOption> all = [
    PingSoundOption(id: kPingSoundDefault, label: 'System Default'),
    PingSoundOption(id: 'sound:chime', label: 'Chime', asset: 'assets/sounds/ping_chime.wav', carrotCost: 10),
    PingSoundOption(id: 'sound:bell', label: 'Bell', asset: 'assets/sounds/ping_bell.wav', carrotCost: 10),
    PingSoundOption(id: 'sound:pop', label: 'Pop', asset: 'assets/sounds/ping_pop.wav', carrotCost: 10),
    PingSoundOption(id: 'sound:marimba', label: 'Marimba', asset: 'assets/sounds/ping_marimba.wav', carrotCost: 10),
  ];

  static PingSoundOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

/// Icon shown for the ping-sound Shop entries — a plain speaker glyph
/// works fine as a shared preview since these are heard, not seen; each
/// card also gets a tap-to-preview play button (see hops_shop_page.dart).
const IconData kPingSoundIcon = Icons.volume_up_outlined;
