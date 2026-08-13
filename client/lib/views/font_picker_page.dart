import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/main.dart' show fontNotifier;

class FontPickerPage extends StatefulWidget {
  const FontPickerPage({super.key});

  @override
  State<FontPickerPage> createState() => _FontPickerPageState();
}

class _FontPickerPageState extends State<FontPickerPage> {
  int _selectedFontIndex = -1;

  @override
  void initState() {
    super.initState();
    _selectedFontIndex = fontNotifier.value;
  }

  Future<void> _selectFont(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_font_index', index);
    fontNotifier.value = index;
    setState(() => _selectedFontIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Font',
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
        actions: [
          if (_selectedFontIndex >= 0)
            TextButton(
              onPressed: () => _selectFont(-1),
              child: const Text('Use system default', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: List.generate(AppFonts.all.length, (index) {
          final f = AppFonts.all[index];
          final isSelected = index == _selectedFontIndex;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              onTap: () => _selectFont(index),
              child: Card(
                elevation: 0,
                color: colors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: isSelected
                      ? BorderSide(color: colors.primary, width: 2)
                      : BorderSide(color: colors.outline.withOpacity(0.15)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Hops',
                              style: f.headlineFont(
                                textStyle: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: colors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'The quick brown fox jumps over the lazy dog.',
                              style: f.bodyFont(
                                textStyle: TextStyle(
                                  fontSize: 13,
                                  color: colors.onSurface.withOpacity(0.7),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              f.name,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isSelected) Icon(Icons.check_circle, color: colors.primary),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
