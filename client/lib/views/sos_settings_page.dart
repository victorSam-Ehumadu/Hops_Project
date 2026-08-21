// lib/views/sos_settings_page.dart
//
// Silent SOS — not an addable feature (see feature_item.dart's header
// comment on Hops Shop for the same "always present, not opt-in" pattern),
// reachable from Profile instead. Explains the two ways to trigger it and
// lets the user actually request the Quick Settings tile — see
// services/sos_service.dart and HopsSosTileService.kt for how the two
// halves of this actually work.
import 'package:flutter/material.dart';
import 'package:client/services/sos_service.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/widgets/hops_background_pattern.dart';

class SosSettingsPage extends StatefulWidget {
  const SosSettingsPage({super.key});

  @override
  State<SosSettingsPage> createState() => _SosSettingsPageState();
}

class _SosSettingsPageState extends State<SosSettingsPage> {
  bool _requesting = false;

  Future<void> _requestTile() async {
    setState(() => _requesting = true);
    final accepted = await SosService.requestAddTile();
    if (!mounted) return;
    setState(() => _requesting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          accepted
              ? "Tile added — swipe down from the top of your screen to see it."
              : "Couldn't add it automatically on this Android version — "
                  "add it manually with the steps below.",
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Silent SOS', style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: HopsBackgroundPattern(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.emergency_outlined, color: colors.primary, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('Two ways to trigger it, without opening Hops first',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: colors.primary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "Either one opens the exact same confirm-then-reason dialog the Emergency Flare "
                    "button already uses on Home — neither ever sends an alert with zero confirmation, "
                    "so an accidental tap or a snug pocket won't trigger a false alarm.",
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.onSurface.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.grid_view_rounded, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Text('1. Quick Settings tile',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: colors.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Adds a Hops SOS tile to the panel you get by swiping down from the top of your "
                    "screen — reachable in one tap, from most lock screens too, without fully unlocking "
                    "or opening any app first.",
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.onSurface.withValues(alpha: 0.7)),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _requesting ? null : _requestTile,
                      icon: _requesting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.add_circle_outline),
                      label: const Text('Add SOS tile'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "Didn't work, or on an older Android version? Add it manually:\n"
                    "Swipe down twice from the top of your screen → tap the pencil/edit icon → "
                    "drag \"Hops SOS\" into your tiles.",
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: colors.onSurface.withValues(alpha: 0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            HopsCard(
              radius: 20,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.volume_down, color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Text('2. Hold Volume Down',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: colors.primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "While Hops is already open (any screen), hold the Volume Down button for 3 "
                    "seconds. Nothing else needed to set up — this one always works, but only while "
                    "the app is on screen, which is why the tile above is the main option.",
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.onSurface.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
