// lib/theme/profile_banners.dart
//
// Discord-style profile banners for the Profile screen header. Six built-in
// looks, all code-drawn (a gradient plus a light CustomPaint pattern) —
// same "no new art assets" approach as every other cosmetic in this app —
// so they cost nothing to ship and scale to any screen width. A separate,
// purchasable "custom banner" capability (see kBannerCustom /
// kCustomBannerUnlockId, wired up in hops_shop_page.dart and
// profile_screen.dart) lets a user upload their own gallery photo instead
// of picking one of these six; that path stores a file path rather than
// picking from this catalog, which is why kBannerCustom is a sentinel id
// deliberately kept OUT of BannerOptions.all.
//
// Local-device rendering only, like most of this app's cosmetics catalogs
// (radar icons, Hopper skins, chat bubbles, ...) — a banner never travels
// to a contact's device the way the Character Avatar does, since there's
// no existing sync channel for it (avatar_path already piggybacks on the
// RFCOMM profile exchange; a banner would need a new one).
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/services/cosmetic_prefs.dart';

enum BannerPattern { none, dots, grid, stars, waves, stripes }

class BannerOption {
  final String id;
  final String label;
  final List<Color> gradient;
  final BannerPattern pattern;
  final int? carrotCost; // null = free, always owned
  const BannerOption({
    required this.id,
    required this.label,
    required this.gradient,
    required this.pattern,
    this.carrotCost,
  });
}

const String kBannerDefault = 'banner:campus_dusk';

// Sentinel — NOT in BannerOptions.all. Selected via a purchased capability
// (kCustomBannerUnlockId) rather than picked from the built-in catalog; see
// this file's header comment.
const String kBannerCustom = 'banner:custom';
const String kCustomBannerUnlockId = 'banner:custom_unlock';
const int kCustomBannerUnlockCost = 40;

class BannerOptions {
  static const List<BannerOption> all = [
    BannerOption(
      id: kBannerDefault,
      label: 'Campus Dusk',
      gradient: [Color(0xFF1B2A6B), Color(0xFF7A3B69), Color(0xFFE07A4F)],
      pattern: BannerPattern.none,
    ),
    BannerOption(
      id: 'banner:neon_nights',
      label: 'Neon Nights',
      gradient: [Color(0xFF6C1FB0), Color(0xFFB3238E), Color(0xFF16C2C2)],
      pattern: BannerPattern.grid,
      carrotCost: 15,
    ),
    BannerOption(
      id: 'banner:meadow',
      label: 'Meadow Bunny',
      gradient: [Color(0xFF1F6B3F), Color(0xFF5EA25A), Color(0xFFBFDD7A)],
      pattern: BannerPattern.dots,
      carrotCost: 15,
    ),
    BannerOption(
      id: 'banner:cosmic',
      label: 'Cosmic Hops',
      gradient: [Color(0xFF0B0F3B), Color(0xFF321E6B), Color(0xFF6A3FA0)],
      pattern: BannerPattern.stars,
      carrotCost: 20,
    ),
    BannerOption(
      id: 'banner:sunrise_gold',
      label: 'Sunrise Gold',
      gradient: [Color(0xFFB8860B), Color(0xFFE0A030), Color(0xFFF2C879)],
      pattern: BannerPattern.waves,
      carrotCost: 15,
    ),
    BannerOption(
      id: 'banner:arcade',
      label: 'Retro Arcade',
      gradient: [Color(0xFFD62839), Color(0xFFF2B705), Color(0xFF1D6FD6)],
      pattern: BannerPattern.stripes,
      carrotCost: 25,
    ),
  ];

  static BannerOption byId(String id) =>
      all.firstWhere((o) => o.id == id, orElse: () => all.first);
}

const String kCustomBannerPathKey = 'custom_banner_path';

/// Lets the user pick a photo from their gallery as their profile banner —
/// gated behind owning kCustomBannerUnlockId (the caller checks that; see
/// hops_shop_page.dart's Custom Banner card). Mirrors
/// edit_identity_screen.dart's _pickAvatar: same gallery source, same
/// "delete the old file before saving the new path" cleanup, same
/// app-documents-directory storage — just wider and lower-quality-capped,
/// tuned for a banner rather than a square avatar. Returns true on
/// success, false if the user canceled the picker.
Future<bool> pickAndSaveCustomBanner() async {
  final picker = ImagePicker();
  final image = await picker.pickImage(
    source: ImageSource.gallery,
    imageQuality: 82,
    maxWidth: 1200,
  );
  if (image == null) return false;

  final prefs = await SharedPreferences.getInstance();
  final previousPath = prefs.getString(kCustomBannerPathKey);

  final bytes = await image.readAsBytes();
  final dir = await getApplicationDocumentsDirectory();
  final fileName = 'banner_${DateTime.now().millisecondsSinceEpoch}.jpg';
  final savedImage = File('${dir.path}/$fileName');
  await savedImage.writeAsBytes(bytes);

  await prefs.setString(kCustomBannerPathKey, savedImage.path);
  await CosmeticPrefs.instance.selectProfileBanner(kBannerCustom);

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
  return true;
}

/// Renders one banner — a diagonal gradient plus a light pattern overlay.
/// Used both as the Shop's small preview card and (at a larger size) as the
/// Profile screen's actual header.
class BannerPreview extends StatelessWidget {
  final BannerOption option;
  final double height;
  final BorderRadius? borderRadius;
  const BannerPreview({super.key, required this.option, this.height = 48, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(10),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: option.gradient,
                ),
              ),
            ),
            if (option.pattern != BannerPattern.none)
              CustomPaint(painter: _BannerPatternPainter(option.pattern)),
          ],
        ),
      ),
    );
  }
}

class _BannerPatternPainter extends CustomPainter {
  final BannerPattern pattern;
  const _BannerPatternPainter(this.pattern);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.16);
    switch (pattern) {
      case BannerPattern.none:
        break;
      case BannerPattern.dots:
        const spacing = 16.0;
        for (double y = 0; y < size.height + spacing; y += spacing) {
          final rowIndex = (y / spacing).round();
          final xOffset = rowIndex.isOdd ? spacing / 2 : 0.0;
          for (double x = 0; x < size.width + spacing; x += spacing) {
            canvas.drawCircle(Offset(x + xOffset, y), 1.6, paint);
          }
        }
        break;
      case BannerPattern.grid:
        final linePaint = paint..strokeWidth = 1;
        const spacing = 14.0;
        for (double x = 0; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
        }
        for (double y = 0; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
        }
        break;
      case BannerPattern.stars:
        // Fixed pseudo-random-looking scatter (deterministic — a real
        // Random would repaint differently every frame since this
        // CustomPainter has no persisted seed) with a few varying sizes so
        // it reads as a starfield rather than a grid.
        final positions = <Offset>[];
        var seed = 7;
        int next() {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          return seed;
        }
        for (var i = 0; i < 40; i++) {
          positions.add(Offset(
            (next() % 1000) / 1000 * size.width,
            (next() % 1000) / 1000 * size.height,
          ));
        }
        for (var i = 0; i < positions.length; i++) {
          canvas.drawCircle(positions[i], i.isEven ? 1.2 : 2.0, paint);
        }
        break;
      case BannerPattern.waves:
        final wavePaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.14)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5;
        for (double baseY = -10; baseY < size.height + 20; baseY += 14) {
          final path = Path()..moveTo(-10, baseY);
          for (double x = -10; x <= size.width + 10; x += 20) {
            path.quadraticBezierTo(x + 5, baseY - 6, x + 20, baseY);
          }
          canvas.drawPath(path, wavePaint);
        }
        break;
      case BannerPattern.stripes:
        final stripePaint = Paint()..color = Colors.white.withValues(alpha: 0.14);
        const stripeWidth = 10.0;
        const gap = 22.0;
        for (double x = -size.height; x < size.width; x += gap) {
          canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), stripePaint..strokeWidth = stripeWidth);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _BannerPatternPainter oldDelegate) => oldDelegate.pattern != pattern;
}
