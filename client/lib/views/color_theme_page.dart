import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/main.dart' show themeNotifier;

// Was a single flat grid of all 12 themes at once — with only Forest Calm/
// Night and Ocean Breeze/Depths as light/dark counterparts to make sense
// of, that many options up front was overwhelming. Splits into a light-vs-
// dark choice first, so someone only ever browses the 6 themes actually
// relevant to the mode they want.
class ColorThemePage extends StatefulWidget {
  const ColorThemePage({super.key});

  @override
  State<ColorThemePage> createState() => _ColorThemePageState();
}

class _ColorThemePageState extends State<ColorThemePage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final lightIndices = <int>[
      for (var i = 0; i < AppThemes.all.length; i++)
        if (AppThemes.all[i].brightness == Brightness.light) i,
    ];
    final darkIndices = <int>[
      for (var i = 0; i < AppThemes.all.length; i++)
        if (AppThemes.all[i].brightness == Brightness.dark) i,
    ];
    final current = AppThemes.all[themeNotifier.value];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Color Theme',
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              "Currently using ${current.name}",
              style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
            ),
          ),
          _ThemeCategoryTile(
            icon: Icons.light_mode_outlined,
            title: 'Light Themes',
            count: lightIndices.length,
            isCurrentCategory: current.brightness == Brightness.light,
            currentName: current.name,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _ColorThemeGridPage(
                    title: 'Light Themes',
                    indices: lightIndices,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 12),
          _ThemeCategoryTile(
            icon: Icons.dark_mode_outlined,
            title: 'Dark Themes',
            count: darkIndices.length,
            isCurrentCategory: current.brightness == Brightness.dark,
            currentName: current.name,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _ColorThemeGridPage(
                    title: 'Dark Themes',
                    indices: darkIndices,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _ThemeCategoryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  final bool isCurrentCategory;
  final String currentName;
  final VoidCallback onTap;

  const _ThemeCategoryTile({
    required this.icon,
    required this.title,
    required this.count,
    required this.isCurrentCategory,
    required this.currentName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: colors.primary),
        ),
        title: Text(
          title,
          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary),
        ),
        subtitle: Text(
          isCurrentCategory ? "$count themes · current: $currentName" : "$count themes",
          style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6)),
        ),
        trailing: Icon(Icons.chevron_right, color: colors.onSurface.withValues(alpha: 0.4)),
        onTap: onTap,
      ),
    );
  }
}

// The actual grid, scoped to one category — [indices] are real indices
// into AppThemes.all (not renumbered), so selecting one here still writes
// the correct global themeNotifier value.
class _ColorThemeGridPage extends StatefulWidget {
  final String title;
  final List<int> indices;
  const _ColorThemeGridPage({required this.title, required this.indices});

  @override
  State<_ColorThemeGridPage> createState() => _ColorThemeGridPageState();
}

class _ColorThemeGridPageState extends State<_ColorThemeGridPage> {
  int _selectedThemeIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedThemeIndex = themeNotifier.value;
  }

  Future<void> _selectTheme(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_theme_index', index);
    themeNotifier.value = index;
    setState(() => _selectedThemeIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title,
          style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.1,
        ),
        itemCount: widget.indices.length,
        itemBuilder: (context, gridIndex) {
          final index = widget.indices[gridIndex];
          final t = AppThemes.all[index];
          final isSelected = index == _selectedThemeIndex;
          return GestureDetector(
            onTap: () => _selectTheme(index),
            child: Card(
              color: t.background,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: isSelected
                    ? BorderSide(color: t.primary, width: 3)
                    : BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Icon(Icons.palette, color: t.primary, size: 32),
                    // Flexible + ellipsis: the fixed 1.1 aspect-ratio grid
                    // cell has no slack for this to wrap onto a second line,
                    // which font_size_page.dart's up-to-1.6x scale (or just
                    // a longer theme name) would otherwise push past the
                    // card's bottom and clip/overflow the selected checkmark
                    // below it.
                    Flexible(
                      child: Text(
                        t.name,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: t.primary,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ColorCircle(color: t.primary),
                        const SizedBox(width: 4),
                        _ColorCircle(color: t.primaryContainer),
                        const SizedBox(width: 4),
                        _ColorCircle(color: t.tertiaryContainer),
                      ],
                    ),
                    if (isSelected) Icon(Icons.check_circle, color: t.primary),
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
