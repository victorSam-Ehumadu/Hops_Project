// lib/views/character_creator_page.dart
//
// The Hops Character Creator — build a custom avatar by combining a base
// creature (avatar_icons.dart), a color tint, and an accessory
// (character_parts.dart), then apply it as your real avatar. This is the
// one Shop cosmetic that genuinely reaches your contacts: "Apply" renders
// the combo to a PNG and saves it through the exact same `avatar_path`
// pipeline edit_identity_screen.dart's photo upload already uses (see
// avatar_icons.dart's applyCharacterAvatar), so it shows up everywhere an
// avatar already does, including the device-to-device avatar exchange.
//
// Each of the three layers is bought independently (same CarrotWallet
// string-id ownership every other cosmetic uses), so unlocking a creature
// once lets you freely recombine it with any owned tint/accessory —
// that's the actual "customizable" part, not a fixed set of presets.
import 'package:flutter/material.dart';
import 'package:client/services/carrot_wallet.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/avatar_icons.dart';
import 'package:client/theme/character_parts.dart';
import 'package:client/services/character_accessory_placement.dart';
import 'package:client/widgets/hops_background_pattern.dart';

class CharacterCreatorPage extends StatefulWidget {
  const CharacterCreatorPage({super.key});

  @override
  State<CharacterCreatorPage> createState() => _CharacterCreatorPageState();
}

class _CharacterCreatorPageState extends State<CharacterCreatorPage> {
  final _wallet = CarrotWallet.instance;
  final _cosmetics = CosmeticPrefs.instance;

  late String _baseId;
  late String _tintId;
  late String _accessoryId;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _wallet.load();
    await _cosmetics.load();
    await CharacterAccessoryPlacements.instance.load();
    _baseId = _cosmetics.characterBase.value;
    _tintId = _cosmetics.characterTint.value;
    _accessoryId = _cosmetics.characterAccessory.value;
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _pickBase(AvatarIconOption o) => _pick(
        id: o.id,
        cost: o.carrotCost,
        label: o.label,
        apply: () {
          _baseId = o.id;
          _cosmetics.selectCharacterBase(o.id);
        },
      );

  Future<void> _pickTint(CharacterTintOption o) => _pick(
        id: o.id,
        cost: o.carrotCost,
        label: o.label,
        apply: () {
          _tintId = o.id;
          _cosmetics.selectCharacterTint(o.id);
        },
      );

  Future<void> _pickAccessory(CharacterAccessoryOption o) => _pick(
        id: o.id,
        cost: o.carrotCost,
        label: o.label,
        apply: () {
          _accessoryId = o.id;
          _cosmetics.selectCharacterAccessory(o.id);
        },
      );

  /// Shared buy-or-select flow: free/owned parts select immediately,
  /// unowned ones attempt a purchase first and only select on success.
  Future<void> _pick({
    required String id,
    required int? cost,
    required String label,
    required VoidCallback apply,
  }) async {
    final alreadyOwned = cost == null || _wallet.owns(id);
    if (!alreadyOwned) {
      final ok = await _wallet.purchase(id, cost);
      if (!ok) {
        _toast("Not enough carrots — you need $cost 🥕.");
        return;
      }
    }
    setState(apply);
  }

  Future<void> _applyAvatar() async {
    await applyCharacterAvatar(
      base: AvatarIconOptions.byId(_baseId),
      tint: CharacterTintOptions.byId(_tintId),
      accessory: CharacterAccessoryOptions.byId(_accessoryId),
    );
    _toast("Character avatar applied!");
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Character Avatar'),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: _wallet.balance,
            builder: (context, balance, _) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(
                children: [
                  const Text('🥕', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 4),
                  Text(
                    CarrotWallet.debugUnlimitedCarrots ? '∞' : '$balance',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : HopsBackgroundPattern(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _wallet.balance,
                  _wallet.owned,
                  CharacterAccessoryPlacements.instance.revision,
                ]),
                builder: (context, _) {
                  final base = AvatarIconOptions.byId(_baseId);
                  final tint = CharacterTintOptions.byId(_tintId);
                  final accessory = CharacterAccessoryOptions.byId(_accessoryId);
                  final placement = CharacterAccessoryPlacements.instance.get(accessory.id);

                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Center(
                        child: _CharacterPreview(
                          key: ValueKey(accessory.id), // fresh drag state per accessory
                          base: base,
                          tint: tint,
                          accessory: accessory,
                          initialDx: placement?.dx ?? accessory.anchorDx,
                          initialDy: placement?.dy ?? accessory.anchorDy,
                          initialScale: placement?.scale ?? accessory.scale,
                          onPlacementChanged: (dx, dy, scale) {
                            CharacterAccessoryPlacements.instance.set(
                              accessory.id,
                              AccessoryPlacement(dx: dx, dy: dy, scale: scale),
                            );
                          },
                        ),
                      ),
                      if (accessory.emoji != null) ...[
                        const SizedBox(height: 6),
                        Center(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Drag to move · pinch to resize',
                                style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55)),
                              ),
                              if (placement != null)
                                TextButton(
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () =>
                                      CharacterAccessoryPlacements.instance.reset(accessory.id),
                                  child: const Text('Reset', style: TextStyle(fontSize: 11)),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Center(
                        child: FilledButton.icon(
                          onPressed: _applyAvatar,
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Apply as Avatar'),
                        ),
                      ),
                      _partSection<AvatarIconOption>(
                        theme: theme,
                        colors: colors,
                        title: 'Base Creature',
                        items: AvatarIconOptions.all,
                        selectedId: _baseId,
                        idOf: (o) => o.id,
                        labelOf: (o) => o.label,
                        costOf: (o) => o.carrotCost,
                        previewOf: (o) => CircleAvatar(
                          radius: 22,
                          backgroundColor: o.background,
                          child: Text(o.emoji, style: const TextStyle(fontSize: 20)),
                        ),
                        onTap: _pickBase,
                      ),
                      _partSection<CharacterTintOption>(
                        theme: theme,
                        colors: colors,
                        title: 'Color',
                        items: CharacterTintOptions.all,
                        selectedId: _tintId,
                        idOf: (o) => o.id,
                        labelOf: (o) => o.label,
                        costOf: (o) => o.carrotCost,
                        previewOf: (o) => CircleAvatar(
                          radius: 22,
                          backgroundColor: o.color ?? colors.surfaceContainerHighest,
                          child: o.color == null
                              ? Icon(Icons.auto_awesome, size: 18, color: colors.onSurface.withValues(alpha: 0.5))
                              : null,
                        ),
                        onTap: _pickTint,
                      ),
                      _partSection<CharacterAccessoryOption>(
                        theme: theme,
                        colors: colors,
                        title: 'Accessory',
                        items: CharacterAccessoryOptions.all,
                        selectedId: _accessoryId,
                        idOf: (o) => o.id,
                        labelOf: (o) => o.label,
                        costOf: (o) => o.carrotCost,
                        previewOf: (o) => CircleAvatar(
                          radius: 22,
                          backgroundColor: colors.surfaceContainerHighest,
                          child: o.emoji != null
                              ? Text(o.emoji!, style: const TextStyle(fontSize: 18))
                              : Icon(Icons.block, size: 16, color: colors.onSurface.withValues(alpha: 0.4)),
                        ),
                        onTap: _pickAccessory,
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                },
              ),
            ),
    );
  }

  Widget _partSection<T>({
    required ThemeData theme,
    required ColorScheme colors,
    required String title,
    required List<T> items,
    required String selectedId,
    required String Function(T) idOf,
    required String Function(T) labelOf,
    required int? Function(T) costOf,
    required Widget Function(T) previewOf,
    required void Function(T) onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: colors.primary)),
          const SizedBox(height: 10),
          SizedBox(
            height: 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final item = items[i];
                final id = idOf(item);
                final cost = costOf(item);
                final isOwned = cost == null || _wallet.owns(id);
                final isSelected = selectedId == id;
                return GestureDetector(
                  onTap: () => onTap(item),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: isSelected ? Border.all(color: colors.primary, width: 3) : null,
                        ),
                        child: Opacity(opacity: isOwned ? 1.0 : 0.5, child: previewOf(item)),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: 64,
                        child: Text(
                          isOwned ? labelOf(item) : '🥕 $cost',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? colors.primary : colors.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Live preview built from plain widgets (not the PNG renderer) so every
/// part change reflects instantly with no async round-trip — the actual
/// PNG (avatar_icons.dart's renderCharacterAvatarPng) is only encoded once,
/// when "Apply as Avatar" is pressed. Layout deliberately mirrors that
/// renderer's proportions (same 0.56 base size, same effective accessory
/// dx/dy/scale it resolves) so what you see here matches what gets saved.
///
/// The accessory itself is draggable/pinch-resizable — onScaleUpdate covers
/// both a one-finger drag (pan) and a two-finger pinch in one gesture
/// recognizer, which is exactly the "move around, resize" the character
/// creator needs. Position is tracked in local widget state during the
/// gesture (so it's silky — no SharedPreferences write per frame) and only
/// reported up to the parent (which persists it via
/// CharacterAccessoryPlacements) once the gesture ends.
class _CharacterPreview extends StatefulWidget {
  final AvatarIconOption base;
  final CharacterTintOption tint;
  final CharacterAccessoryOption accessory;
  final double initialDx;
  final double initialDy;
  final double initialScale;
  final void Function(double dx, double dy, double scale) onPlacementChanged;

  const _CharacterPreview({
    super.key,
    required this.base,
    required this.tint,
    required this.accessory,
    required this.initialDx,
    required this.initialDy,
    required this.initialScale,
    required this.onPlacementChanged,
  });

  @override
  State<_CharacterPreview> createState() => _CharacterPreviewState();
}

class _CharacterPreviewState extends State<_CharacterPreview> {
  static const double _size = 140.0;

  // NOT initialized inline from `widget` — the State's constructor (which
  // is where field initializers run) executes before the framework has
  // attached this State to its widget, so `widget.initialDx` isn't
  // available yet at that point. initState() is the earliest place it is.
  late double _dx;
  late double _dy;
  late double _scale;

  // Captured at gesture start so drag/pinch deltas are relative to where
  // the gesture began, not accumulated frame-over-frame (which would drift).
  Offset? _gestureStartFocal;
  double? _gestureStartDx, _gestureStartDy, _gestureStartScale;

  @override
  void initState() {
    super.initState();
    _dx = widget.initialDx;
    _dy = widget.initialDy;
    _scale = widget.initialScale;
  }

  @override
  void didUpdateWidget(covariant _CharacterPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Resyncs from an externally-triggered change — namely the "Reset"
    // button, which clears the persisted placement and so changes what the
    // parent passes as initialDx/Dy/Scale without this widget's own key
    // changing (that only happens on an accessory SWITCH, handled by
    // initState instead). A drag/pinch in progress never lands here: this
    // widget only reports its position back to the parent (which is what
    // would cause new initial* values to flow back down) once the gesture
    // already ended.
    if (oldWidget.initialDx != widget.initialDx ||
        oldWidget.initialDy != widget.initialDy ||
        oldWidget.initialScale != widget.initialScale) {
      setState(() {
        _dx = widget.initialDx;
        _dy = widget.initialDy;
        _scale = widget.initialScale;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final creature = Text(widget.base.emoji, style: const TextStyle(fontSize: _size * 0.56));
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(color: widget.base.background, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: widget.tint.color != null
                ? ColorFiltered(
                    colorFilter: ColorFilter.mode(widget.tint.color!, BlendMode.srcIn),
                    child: creature,
                  )
                : creature,
          ),
          if (widget.accessory.emoji != null)
            Positioned(
              left: _size * _dx - (_size * _scale) / 2,
              top: _size * _dy - (_size * _scale) / 2,
              child: GestureDetector(
                onScaleStart: (details) {
                  _gestureStartFocal = details.focalPoint;
                  _gestureStartDx = _dx;
                  _gestureStartDy = _dy;
                  _gestureStartScale = _scale;
                },
                onScaleUpdate: (details) {
                  final startFocal = _gestureStartFocal;
                  if (startFocal == null) return;
                  final deltaLocal = (details.focalPoint - startFocal) / _size;
                  setState(() {
                    _dx = (_gestureStartDx! + deltaLocal.dx)
                        .clamp(CharacterAccessoryPlacements.minPos, CharacterAccessoryPlacements.maxPos);
                    _dy = (_gestureStartDy! + deltaLocal.dy)
                        .clamp(CharacterAccessoryPlacements.minPos, CharacterAccessoryPlacements.maxPos);
                    _scale = (_gestureStartScale! * details.scale)
                        .clamp(CharacterAccessoryPlacements.minScale, CharacterAccessoryPlacements.maxScale);
                  });
                },
                onScaleEnd: (_) => widget.onPlacementChanged(_dx, _dy, _scale),
                child: Container(
                  width: _size * _scale,
                  height: _size * _scale,
                  // A faint dashed-look ring hints this thing is grabbable —
                  // without it nothing on screen suggests the accessory
                  // (unlike every other tap target in this app) responds to
                  // a drag instead of a tap.
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    widget.accessory.emoji!,
                    style: TextStyle(fontSize: _size * _scale * 0.82),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
