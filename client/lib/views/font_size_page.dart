import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:client/main.dart' show fontScaleNotifier;

// A handful of named steps rather than a free-dragging slider — "Small" /
// "Default" / "Large" / "Extra Large" is easier to reason about than
// picking an arbitrary percentage, and keeps everyone within the same
// range the rest of the app (radar labels, nav pill, chat bubbles) has
// actually been checked against.
const List<_FontSizeStep> _steps = [
  _FontSizeStep('Small', 0.85),
  _FontSizeStep('Default', 1.0),
  _FontSizeStep('Large', 1.15),
  _FontSizeStep('Extra Large', 1.3),
];

class _FontSizeStep {
  final String label;
  final double scale;
  const _FontSizeStep(this.label, this.scale);
}

class FontSizePage extends StatefulWidget {
  const FontSizePage({super.key});

  @override
  State<FontSizePage> createState() => _FontSizePageState();
}

class _FontSizePageState extends State<FontSizePage> {
  late double _scale = fontScaleNotifier.value;

  int get _closestStepIndex {
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < _steps.length; i++) {
      final diff = (_steps[i].scale - _scale).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  Future<void> _applyStep(int index) async {
    final scale = _steps[index].scale;
    setState(() => _scale = scale);
    fontScaleNotifier.value = scale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_scale', scale);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final currentIndex = _closestStepIndex;

    return Scaffold(
      appBar: AppBar(
        title: Text('Font Size', style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Live preview so a choice is felt immediately rather than only
          // discovered after leaving the screen.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    'Hops',
                    style: TextStyle(fontSize: 20 * _scale, fontWeight: FontWeight.bold, color: colors.primary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is what regular text will look like around the app.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14 * _scale, color: colors.onSurface.withOpacity(0.75)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _FontSizeOptionTile(
                label: _steps[i].label,
                selected: i == currentIndex,
                previewScale: _steps[i].scale,
                onTap: () => _applyStep(i),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            "This changes text size within Hops only — it doesn't affect your phone's system font size.",
            style: TextStyle(fontSize: 12, color: colors.onSurface.withOpacity(0.5)),
          ),
        ],
      ),
    );
  }
}

class _FontSizeOptionTile extends StatelessWidget {
  final String label;
  final bool selected;
  final double previewScale;
  final VoidCallback onTap;

  const _FontSizeOptionTile({
    required this.label,
    required this.selected,
    required this.previewScale,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: selected ? colors.primaryContainer.withOpacity(0.3) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected ? BorderSide(color: colors.primary, width: 2) : BorderSide.none,
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15 * previewScale,
            color: colors.primary,
          ),
        ),
        trailing: selected ? Icon(Icons.check_circle, color: colors.primary) : null,
      ),
    );
  }
}
