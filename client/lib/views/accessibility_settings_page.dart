// lib/views/accessibility_settings_page.dart
//
// One place for everything accessibility-related — some of it lives here
// as new toggles (accessibility_prefs.dart), some of it already existed
// elsewhere and is just linked to from here so it isn't a second thing to
// go hunting for (Font Size was previously only reachable from Customize
// Hops).
import 'package:flutter/material.dart';
import 'package:client/services/accessibility_prefs.dart';
import 'package:client/views/font_size_page.dart';
import 'package:client/widgets/hops_card.dart';
import 'package:client/widgets/hops_background_pattern.dart';

class AccessibilitySettingsPage extends StatefulWidget {
  const AccessibilitySettingsPage({super.key});

  @override
  State<AccessibilitySettingsPage> createState() => _AccessibilitySettingsPageState();
}

class _AccessibilitySettingsPageState extends State<AccessibilitySettingsPage> {
  final _prefs = AccessibilityPrefs.instance;

  @override
  void initState() {
    super.initState();
    _prefs.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Accessibility', style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
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
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.text_fields, color: colors.primary),
                    title: const Text('Text Size', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    subtitle: Text(
                      'Make text throughout Hops bigger or smaller',
                      style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.65)),
                    ),
                    trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const FontSizePage()),
                    ),
                  ),
                  Divider(height: 1, color: colors.onSurface.withValues(alpha: 0.08)),
                  ValueListenableBuilder<bool>(
                    valueListenable: _prefs.readMessagesAloud,
                    builder: (context, value, _) => SwitchListTile(
                      secondary: Icon(Icons.record_voice_over_outlined, color: colors.primary),
                      title: const Text('Read Messages Aloud', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(
                        'Speak new 1:1 chat messages out loud as they arrive',
                        style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.65)),
                      ),
                      value: value,
                      onChanged: _prefs.setReadMessagesAloud,
                    ),
                  ),
                  Divider(height: 1, color: colors.onSurface.withValues(alpha: 0.08)),
                  ValueListenableBuilder<bool>(
                    valueListenable: _prefs.speakWatchMeAlerts,
                    builder: (context, value, _) => SwitchListTile(
                      secondary: Icon(Icons.hearing_outlined, color: colors.primary),
                      title: const Text('Speak Watch Me Alerts', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(
                        'Say it out loud when a buddy goes out of range, and again when '
                        'they come back — so you can keep your eyes up while walking',
                        style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.65)),
                      ),
                      value: value,
                      onChanged: _prefs.setSpeakWatchMeAlerts,
                    ),
                  ),
                  Divider(height: 1, color: colors.onSurface.withValues(alpha: 0.08)),
                  ValueListenableBuilder<bool>(
                    valueListenable: _prefs.colorblindMode,
                    builder: (context, value, _) => SwitchListTile(
                      secondary: Icon(Icons.palette_outlined, color: colors.primary),
                      title: const Text('Colorblind-Friendly Signals', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(
                        'Uses a blue/orange/purple palette for Watch Me\'s proximity indicator instead of red/yellow/green',
                        style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.65)),
                      ),
                      value: value,
                      onChanged: _prefs.setColorblindMode,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                "Hops also respects your device's own system text size and screen-reader "
                "settings wherever Android/iOS lets an app inherit them automatically.",
                style: TextStyle(fontSize: 11.5, color: colors.onSurface.withValues(alpha: 0.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
