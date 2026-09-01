// lib/views/hops_shop_page.dart
//
// The Hops Shop — spend carrots (earned in Hops Hopper/Hops Wordle) on
// premium customization. Covers every cosmetic catalog in lib/theme/:
// color themes, radar icons, Hopper bunny skins, avatar frames, profile
// banners, chat bubble skins, Wordle tile palettes, username flair, and
// notification ping sounds — plus a banner into the standalone Character
// Creator
// (character_creator_page.dart), which is its own full page rather than a
// horizontal-scroll section since it's a build-then-apply flow, not a
// simple buy-a-fixed-thing list. See CarrotWallet's header comment for why
// this is entirely local/on-device, no purchase-verification backend
// involved, and cosmetic_prefs.dart's header comment for which of these
// (the Character Avatar — see theme/avatar_icons.dart) actually reach a
// contact vs. which are your-own-device-only.
//
// Color Themes keeps its own bespoke section (swatches, apply-through-
// themeNotifier) since it predates the rest and already has real
// per-theme visuals worth keeping. Every other category is rendered
// through the generic _Entry/_buildSection machinery below so adding a
// 10th cosmetic catalog later doesn't mean writing a 10th near-identical
// UI block by hand.
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:client/main.dart' show themeNotifier;
import 'package:client/services/carrot_wallet.dart';
import 'package:client/services/cosmetic_prefs.dart';
import 'package:client/theme/app_theme.dart';
import 'package:client/theme/radar_icons.dart';
import 'package:client/theme/hopper_skins.dart';
import 'package:client/theme/avatar_frames.dart';
import 'package:client/theme/chat_bubble_skins.dart';
import 'package:client/theme/wordle_palettes.dart';
import 'package:client/theme/username_flairs.dart';
import 'package:client/theme/ping_sound_packs.dart';
import 'package:client/theme/profile_banners.dart';
import 'package:client/views/character_creator_page.dart';
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:shared_preferences/shared_preferences.dart';

class HopsShopPage extends StatefulWidget {
  const HopsShopPage({super.key});

  @override
  State<HopsShopPage> createState() => _HopsShopPageState();
}

class _HopsShopPageState extends State<HopsShopPage> {
  final _wallet = CarrotWallet.instance;
  final _cosmetics = CosmeticPrefs.instance;

  @override
  void initState() {
    super.initState();
    _wallet.load();
    _cosmetics.load();
  }

  List<AppTheme> get _shopThemes =>
      AppThemes.all.where((t) => t.carrotCost != null).toList();

  Future<void> _buyTheme(AppTheme theme) async {
    final ok = await _wallet.purchase(theme.name, theme.carrotCost!);
    _toast(ok
        ? "Unlocked ${theme.name}! Apply it below, or from Customize Hops."
        : "Not enough carrots — you need ${theme.carrotCost} 🥕.");
  }

  Future<void> _applyTheme(AppTheme theme) async {
    final index = AppThemes.all.indexOf(theme);
    if (index < 0) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_theme_index', index);
    themeNotifier.value = index;
    _toast("${theme.name} applied.");
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  // ── Generic buy/select flow shared by every non-theme category below ──
  Future<void> _buyGeneric(String id, int? cost, String label) async {
    final ok = await _wallet.purchase(id, cost ?? 0);
    _toast(ok ? "Unlocked $label!" : "Not enough carrots — you need $cost 🥕.");
  }

  Future<void> _previewSound(PingSoundOption option) async {
    if (option.asset == null) return;
    try {
      final player = AudioPlayer();
      await player.setAsset(option.asset!);
      await player.play();
      Future.delayed(const Duration(seconds: 2), player.dispose);
    } catch (_) {
      _toast("Couldn't preview that sound.");
    }
  }

  Future<void> _buyCustomBannerUnlock() async {
    final ok = await _wallet.purchase(kCustomBannerUnlockId, kCustomBannerUnlockCost);
    if (!ok) {
      _toast("Not enough carrots — you need $kCustomBannerUnlockCost 🥕.");
      return;
    }
    _toast("Custom banners unlocked! Tap the card again to pick a photo.");
  }

  Future<void> _pickCustomBanner() async {
    final ok = await pickAndSaveCustomBanner();
    _toast(ok ? "Custom banner applied — see it on your Profile." : "No photo selected.");
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hops Shop'),
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
      body: HopsBackgroundPattern(
        // A single merged listener for every wallet/cosmetic-selection
        // notifier this page reads — same reasoning as before, just scaled
        // up: any one of these changing (a purchase, a re-selection) should
        // refresh the whole page, and listening to only some of them would
        // leave the others stale.
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _wallet.balance,
            _wallet.owned,
            _cosmetics.radarIcon,
            _cosmetics.hopperSkin,
            _cosmetics.avatarFrame,
            _cosmetics.bubbleSkin,
            _cosmetics.wordlePalette,
            _cosmetics.flair,
            _cosmetics.pingSound,
            _cosmetics.profileBanner,
          ]),
          builder: (context, _) {
            final balance = _wallet.balance.value;
            final owned = _wallet.owned.value;
            bool canAfford(int? cost) =>
                CarrotWallet.debugUnlimitedCarrots || balance >= (cost ?? 0);

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionHeader(theme, colors, 'Color Themes',
                    'Earn carrots by playing Hops Hopper and Hops Wordle.'),
                const SizedBox(height: 14),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.92,
                  ),
                  itemCount: _shopThemes.length,
                  itemBuilder: (context, i) {
                    final t = _shopThemes[i];
                    final isOwned = owned.contains(t.name);
                    return _ShopThemeCard(
                      themeItem: t,
                      isOwned: isOwned,
                      isApplied: themeNotifier.value == AppThemes.all.indexOf(t),
                      canAfford: canAfford(t.carrotCost),
                      onBuy: () => _buyTheme(t),
                      onApply: () => _applyTheme(t),
                    );
                  },
                ),

                _buildSection<RadarIconOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Radar Icons',
                  subtitle: "What a nearby Hopper's blip looks like on your own radar.",
                  items: RadarIconOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => _emojiPreview(o.emoji, colors, fallbackDot: true),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.radarIcon.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectRadarIcon(o.id),
                ),

                _buildSection<HopperSkinOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Hopper Bunny Skins',
                  subtitle: 'Recolors the Hops Hopper bunny.',
                  items: HopperSkinOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => Icon(Icons.cruelty_free, size: 30, color: o.color ?? colors.onSurface),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.hopperSkin.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectHopperSkin(o.id),
                ),

                _buildSection<AvatarFrameOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Avatar Frames',
                  subtitle: 'A decorative ring around your own avatar.',
                  items: AvatarFrameOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => HopsAvatarFrame(
                    frameId: o.id,
                    avatarDiameter: 32,
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: colors.primaryContainer,
                      child: Icon(Icons.cruelty_free, size: 16, color: colors.primary),
                    ),
                  ),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.avatarFrame.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectAvatarFrame(o.id),
                ),

                Padding(
                  padding: const EdgeInsets.only(top: 26),
                  child: Card(
                    color: colors.primaryContainer.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      leading: Icon(Icons.face_retouching_natural, color: colors.primary, size: 30),
                      title: Text('Character Avatar',
                          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
                      subtitle: const Text(
                        'Build a custom avatar: pick a creature, a color, and an accessory — '
                        'it becomes your real avatar, so contacts see it too.',
                        style: TextStyle(fontSize: 12),
                      ),
                      trailing: Icon(Icons.chevron_right, color: colors.primary),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const CharacterCreatorPage()),
                      ).then((_) => setState(() {})),
                    ),
                  ),
                ),

                _buildSection<BannerOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Profile Banners',
                  subtitle: 'A header image behind your name on your Profile screen.',
                  items: BannerOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => BannerPreview(option: o, height: 34, borderRadius: BorderRadius.circular(6)),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.profileBanner.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectProfileBanner(o.id),
                ),

                Padding(
                  padding: const EdgeInsets.only(top: 26),
                  child: Card(
                    color: colors.primaryContainer.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      leading: Icon(Icons.image_outlined, color: colors.primary, size: 30),
                      title: Text('Custom Banner',
                          style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary)),
                      subtitle: Text(
                        owned.contains(kCustomBannerUnlockId)
                            ? 'Unlocked — tap to choose a photo from your gallery.'
                            : 'Unlock the ability to use your own photo as your banner.',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: owned.contains(kCustomBannerUnlockId)
                          ? Icon(Icons.chevron_right, color: colors.primary)
                          : FilledButton(
                              onPressed: canAfford(kCustomBannerUnlockCost) ? _buyCustomBannerUnlock : null,
                              style: FilledButton.styleFrom(minimumSize: const Size(0, 32)),
                              child: const Text('🥕 $kCustomBannerUnlockCost'),
                            ),
                      onTap: owned.contains(kCustomBannerUnlockId) ? _pickCustomBanner : null,
                    ),
                  ),
                ),

                _buildSection<BubbleSkinOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Chat Bubble Skins',
                  subtitle: 'Recolors your own outgoing chat bubbles.',
                  items: BubbleSkinOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => Container(
                    width: 40,
                    height: 26,
                    decoration: BoxDecoration(
                      color: o.bubbleColor ?? colors.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.bubbleSkin.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectBubbleSkin(o.id),
                ),

                _buildSection<WordlePalette>(
                  theme: theme,
                  colors: colors,
                  title: 'Wordle Tile Palette',
                  subtitle: 'Alternate correct/present tile colors for Hops Wordle.',
                  items: WordlePalettes.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _swatchSquare(o.correct),
                      const SizedBox(width: 3),
                      _swatchSquare(o.present),
                    ],
                  ),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.wordlePalette.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectWordlePalette(o.id),
                ),

                _buildSection<FlairOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Username Flair',
                  subtitle: 'A small badge shown next to your name on your Profile.',
                  items: FlairOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => _emojiPreview(o.emoji, colors, fallbackDot: false),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.flair.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectFlair(o.id),
                ),

                _buildSection<PingSoundOption>(
                  theme: theme,
                  colors: colors,
                  title: 'Notification Ping Sounds',
                  subtitle: 'Plays for friend requests & messages while Hops is open — '
                      'Emergency Flare always keeps its own siren for everyone.',
                  items: PingSoundOptions.all,
                  idOf: (o) => o.id,
                  labelOf: (o) => o.label,
                  costOf: (o) => o.carrotCost,
                  previewOf: (o) => IconButton(
                    icon: Icon(kPingSoundIcon, color: colors.primary),
                    iconSize: 22,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: o.asset == null ? null : 'Preview',
                    onPressed: o.asset == null ? null : () => _previewSound(o),
                  ),
                  owned: owned,
                  canAfford: canAfford,
                  currentId: _cosmetics.pingSound.value,
                  onBuy: (o) => _buyGeneric(o.id, o.carrotCost, o.label),
                  onSelect: (o) => _cosmetics.selectPingSound(o.id),
                ),

                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, ColorScheme colors, String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold, color: colors.primary)),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.55))),
      ],
    );
  }

  Widget _emojiPreview(String? emoji, ColorScheme colors, {required bool fallbackDot}) {
    if (emoji == null) {
      return fallbackDot
          ? Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
            )
          : Text('—', style: TextStyle(fontSize: 20, color: colors.onSurface.withValues(alpha: 0.4)));
    }
    return Text(emoji, style: const TextStyle(fontSize: 26));
  }

  Widget _swatchSquare(Color color) => Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      );

  /// Generic section: a horizontally scrolling row of cards for one
  /// cosmetic catalog. `T` is whatever that catalog's option class is
  /// (RadarIconOption, HopperSkinOption, ...) — every field this needs off
  /// it is passed in as a small accessor closure instead of requiring a
  /// shared interface, so none of the catalog files in lib/theme/ need to
  /// know this page exists.
  Widget _buildSection<T>({
    required ThemeData theme,
    required ColorScheme colors,
    required String title,
    required String subtitle,
    required List<T> items,
    required String Function(T) idOf,
    required String Function(T) labelOf,
    required int? Function(T) costOf,
    required Widget Function(T) previewOf,
    required Set<String> owned,
    required bool Function(int? cost) canAfford,
    required String? currentId,
    required Future<void> Function(T) onBuy,
    required Future<void> Function(T) onSelect,
    String selectLabel = 'Select',
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(theme, colors, title, subtitle),
          const SizedBox(height: 10),
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final item = items[i];
                final id = idOf(item);
                final cost = costOf(item);
                final isOwned = cost == null || owned.contains(id);
                final isSelected = currentId != null && currentId == id;
                return _CosmeticCard(
                  label: labelOf(item),
                  preview: previewOf(item),
                  isOwned: isOwned,
                  isSelected: isSelected,
                  canAfford: canAfford(cost),
                  cost: cost,
                  selectLabel: selectLabel,
                  onBuy: () => onBuy(item),
                  onSelect: () => onSelect(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One card in a generic cosmetic section — Buy (locked/unaffordable),
/// Select/Selected (owned), matching _ShopThemeCard's interaction model
/// below but with a caller-supplied preview widget instead of a fixed
/// palette icon+swatches layout.
class _CosmeticCard extends StatelessWidget {
  final String label;
  final Widget preview;
  final bool isOwned;
  final bool isSelected;
  final bool canAfford;
  final int? cost;
  final String selectLabel;
  final VoidCallback onBuy;
  final VoidCallback onSelect;

  const _CosmeticCard({
    required this.label,
    required this.preview,
    required this.isOwned,
    required this.isSelected,
    required this.canAfford,
    required this.cost,
    required this.selectLabel,
    required this.onBuy,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: 96,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: isSelected ? Border.all(color: colors.primary, width: 2) : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          SizedBox(height: 34, child: Center(child: preview)),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          if (isOwned)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isSelected ? null : onSelect,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  textStyle: const TextStyle(fontSize: 11),
                ),
                child: Text(isSelected ? 'Active' : selectLabel),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canAfford ? onBuy : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  textStyle: const TextStyle(fontSize: 11),
                ),
                child: Text('🥕 $cost'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShopThemeCard extends StatelessWidget {
  final AppTheme themeItem;
  final bool isOwned;
  final bool isApplied;
  final bool canAfford;
  final VoidCallback onBuy;
  final VoidCallback onApply;

  const _ShopThemeCard({
    required this.themeItem,
    required this.isOwned,
    required this.isApplied,
    required this.canAfford,
    required this.onBuy,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final t = themeItem;
    return Card(
      color: t.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: isApplied ? BorderSide(color: t.primary, width: 3) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Icon(Icons.palette, color: t.primary, size: 28),
            Flexible(
              child: Text(
                t.name,
                style: TextStyle(fontWeight: FontWeight.bold, color: t.primary, fontSize: 13),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _swatch(t.primary),
                const SizedBox(width: 4),
                _swatch(t.primaryContainer),
                const SizedBox(width: 4),
                _swatch(t.tertiaryContainer),
              ],
            ),
            if (isOwned)
              FilledButton(
                onPressed: isApplied ? null : onApply,
                style: FilledButton.styleFrom(
                  backgroundColor: t.primary,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(isApplied ? 'Applied' : 'Apply', style: const TextStyle(fontSize: 12)),
              )
            else
              FilledButton(
                onPressed: canAfford ? onBuy : null,
                style: FilledButton.styleFrom(
                  backgroundColor: t.primary,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text('🥕 ${t.carrotCost}', style: const TextStyle(fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(Color color) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white),
        ),
      );
}
