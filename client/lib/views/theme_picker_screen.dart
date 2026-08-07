import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/main.dart' show themeNotifier;   // import the notifier

class ThemePickerScreen extends StatefulWidget {
  const ThemePickerScreen({super.key});

  @override
  State<ThemePickerScreen> createState() => _ThemePickerScreenState();
}

class _ThemePickerScreenState extends State<ThemePickerScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = themeNotifier.value;
  }

  Future<void> _selectTheme(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_theme_index', index);
    themeNotifier.value = index;

    // No need to restart – the HopsRoot will rebuild automatically
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Choose a Theme',
          style: TextStyle(
            color: colors.primary,          // always visible
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,         // back button visible
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.1,
        ),
        itemCount: AppThemes.all.length,
        itemBuilder: (context, index) {
          final theme = AppThemes.all[index];
          final isSelected = index == _selectedIndex;
          return GestureDetector(
            onTap: () => _selectTheme(index),
            child: Card(
              color: theme.background,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isSelected
                    ? BorderSide(color: theme.primary, width: 3)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Icon(Icons.palette, color: theme.primary, size: 32),
                    Text(
                      theme.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.primary,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ColorCircle(color: theme.primary),
                        const SizedBox(width: 4),
                        _ColorCircle(color: theme.primaryContainer),
                        const SizedBox(width: 4),
                        _ColorCircle(color: theme.tertiaryContainer),
                      ],
                    ),
                    if (isSelected)
                      Icon(Icons.check_circle, color: theme.primary),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ColorCircle extends StatelessWidget {
  final Color color;
  const _ColorCircle({required this.color});

  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white),
      ),
    );
  }
}