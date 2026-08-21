// lib/theme/avatar_icons.dart
//
// Base creatures for the Hops Character Creator (character_creator_page.dart)
// — bunny/fox/owl/cat/turtle/dragon. Unlike every other cosmetic catalog in
// this directory, a character avatar genuinely reaches your contacts:
// applyCharacterAvatar renders the composed creature+tint+accessory to a
// PNG and saves it through the exact same `avatar_path` SharedPreferences
// key that edit_identity_screen.dart's gallery-upload flow already uses,
// so every existing avatar call site (app bar, Profile screen, and the
// device-to-device avatar exchange in rfcomm_chat_service.dart's
// sendProfile) picks it up automatically with zero changes to any of
// them. Deliberately reusing that pipeline rather than inventing a second
// "avatar kind" flag — a rendered PNG file IS a valid avatar.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/character_parts.dart';
import 'package:client/services/character_accessory_placement.dart';
import 'package:client/services/avatar_path_notifier.dart';

class AvatarIconOption {
  final String id;
  final String label;
  final String emoji;
  final Color background;
  final int? carrotCost; // null = free
  const AvatarIconOption({
    required this.id,
    required this.label,
    required this.emoji,
    required this.background,
    this.carrotCost,
  });
}

class AvatarIconOptions {
  static const List<AvatarIconOption> all = [
    AvatarIconOption(id: 'avatar:bunny', label: 'Bunny', emoji: '🐰', background: Color(0xFF165C6F), carrotCost: 10),
    AvatarIconOption(id: 'avatar:fox', label: 'Fox', emoji: '🦊', background: Color(0xFFB8641A), carrotCost: 10),
    AvatarIconOption(id: 'avatar:owl', label: 'Owl', emoji: '🦉', background: Color(0xFF5B4636), carrotCost: 10),
    AvatarIconOption(id: 'avatar:cat', label: 'Cat', emoji: '🐱', background: Color(0xFF6B4E9B), carrotCost: 10),
    AvatarIconOption(id: 'avatar:turtle', label: 'Turtle', emoji: '🐢', background: Color(0xFF2E7D5B), carrotCost: 10),
    AvatarIconOption(id: 'avatar:dragon', label: 'Dragon', emoji: '🐉', background: Color(0xFF9B2D2D), carrotCost: 15),
  ];

  static AvatarIconOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

/// Composites [base] + [tint] + [accessory] onto one circular PNG. Plain
/// dart:ui, no BuildContext needed, so this can be called from a button's
/// onTap same as any other async action. Tint uses a saveLayer +
/// BlendMode.srcIn (the canvas equivalent of the ColorFiltered widget
/// trick used elsewhere, e.g. hops_hopper_page.dart's bunny) to flatten
/// the emoji glyph into a solid-color silhouette — same visual language
/// as the Hopper skins, applied here to whichever creature is picked.
/// Accessory is drawn last, layered directly onto the creature at that
/// accessory's own anchor point (see CharacterAccessoryOption.anchorDx/Dy/
/// scale in character_parts.dart) — a hat sits above the head, a bow tie
/// sits below the chin, and so on, so it reads as *worn* rather than as a
/// sticker in the corner. Emoji art isn't on a shared template across
/// different base creatures, so these are approximate hand-tuned anchors,
/// not a pixel-perfect fit for every creature — but every base in this
/// catalog is roughly a round, front-facing face, so one shared anchor per
/// accessory works well enough across all of them.
Future<Uint8List> renderCharacterAvatarPng({
  required AvatarIconOption base,
  required CharacterTintOption tint,
  required CharacterAccessoryOption accessory,
  double size = 256,
}) async {
  // A user-dragged/pinched placement (character_accessory_placement.dart)
  // overrides the accessory's own built-in anchor/scale if they've ever
  // customized this specific accessory — see character_creator_page.dart's
  // _CharacterPreview, which is what actually produces these.
  final placement = CharacterAccessoryPlacements.instance.get(accessory.id);
  final accessoryDx = placement?.dx ?? accessory.anchorDx;
  final accessoryDy = placement?.dy ?? accessory.anchorDy;
  final accessoryScale = placement?.scale ?? accessory.scale;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final fullRect = Rect.fromLTWH(0, 0, size, size);

  canvas.drawCircle(Offset(size / 2, size / 2), size / 2, Paint()..color = base.background);

  final baseTextPainter = TextPainter(
    text: TextSpan(text: base.emoji, style: TextStyle(fontSize: size * 0.56)),
    textDirection: TextDirection.ltr,
  );
  baseTextPainter.layout();
  final baseOffset = Offset(
    (size - baseTextPainter.width) / 2,
    (size - baseTextPainter.height) / 2,
  );
  if (tint.color != null) {
    canvas.saveLayer(fullRect, Paint()..colorFilter = ColorFilter.mode(tint.color!, BlendMode.srcIn));
    baseTextPainter.paint(canvas, baseOffset);
    canvas.restore();
  } else {
    baseTextPainter.paint(canvas, baseOffset);
  }

  if (accessory.emoji != null) {
    final accentTextPainter = TextPainter(
      text: TextSpan(text: accessory.emoji, style: TextStyle(fontSize: size * accessoryScale)),
      textDirection: TextDirection.ltr,
    );
    accentTextPainter.layout();
    final anchor = Offset(size * accessoryDx, size * accessoryDy);
    accentTextPainter.paint(
      canvas,
      Offset(anchor.dx - accentTextPainter.width / 2, anchor.dy - accentTextPainter.height / 2),
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(size.toInt(), size.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

/// Renders the [base]+[tint]+[accessory] combo and sets it as the user's
/// avatar — writes it to disk and points the existing `avatar_path` pref
/// at it, deleting whatever avatar file (uploaded photo or an earlier
/// character render) it's replacing. Mirrors edit_identity_screen.dart's
/// _pickAvatar cleanup exactly.
Future<void> applyCharacterAvatar({
  required AvatarIconOption base,
  required CharacterTintOption tint,
  required CharacterAccessoryOption accessory,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final previousPath = prefs.getString('avatar_path');

  final bytes = await renderCharacterAvatarPng(base: base, tint: tint, accessory: accessory);
  final dir = await getApplicationDocumentsDirectory();
  final fileName = 'avatar_character_${DateTime.now().millisecondsSinceEpoch}.png';
  final savedImage = File('${dir.path}/$fileName');
  await savedImage.writeAsBytes(bytes);

  await prefs.setString('avatar_path', savedImage.path);
  avatarPathRevision.value++;

  if (previousPath != null && previousPath != savedImage.path) {
    final oldFile = File(previousPath);
    if (await oldFile.exists()) {
      try {
        await oldFile.delete();
      } catch (_) {
        // Best-effort cleanup — not worth surfacing an error for this.
      }
    }
  }
}
