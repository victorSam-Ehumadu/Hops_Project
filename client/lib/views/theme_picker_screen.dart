import 'package:flutter/material.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/main.dart' show themeNotifier, fontNotifier, fontScaleNotifier;
import 'package:client/views/color_theme_page.dart';
import 'package:client/views/font_picker_page.dart';
import 'package:client/views/font_size_page.dart';

// The "Customize Hops" hub — color theme and font used to be crammed onto
// one long scrolling screen; split into their own dedicated pages (each
// with room to breathe, and its own AppBar/back button) reached from here,
// same shape as Profile → Account Management's own hub-and-spoke pattern.
class ThemePickerScreen extends StatefulWidget {
  const ThemePickerScreen({super.key});

  @override
  State<ThemePickerScreen> createState() => _ThemePickerScreenState();
}

class _ThemePickerScreenState extends State<ThemePickerScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final currentThemeName = AppThemes.all[themeNotifier.value].name;
    final currentFontName =
        fontNotifier.value >= 0 ? AppFonts.all[fontNotifier.value].name : 'System default';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Customize Hops',
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            leading: Icon(Icons.palette_outlined, color: colors.primary),
            title: Text(
              'Color Theme',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.primary),
            ),
            subtitle: Text(
              currentThemeName,
              style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
            ),
            trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withOpacity(0.4)),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ColorThemePage()),
            ).then((_) => setState(() {})),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            leading: Icon(Icons.text_fields, color: colors.primary),
            title: Text(
              'Font',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.primary),
            ),
            subtitle: Text(
              currentFontName,
              style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
            ),
            trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withOpacity(0.4)),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FontPickerPage()),
            ).then((_) => setState(() {})),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            leading: Icon(Icons.format_size, color: colors.primary),
            title: Text(
              'Font Size',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: colors.primary),
            ),
            subtitle: Text(
              "${(fontScaleNotifier.value * 100).round()}%",
              style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.7)),
            ),
            trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurface.withOpacity(0.4)),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FontSizePage()),
            ).then((_) => setState(() {})),
          ),
        ],
      ),
    );
  }
}
