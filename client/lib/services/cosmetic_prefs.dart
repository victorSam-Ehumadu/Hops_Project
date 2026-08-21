// lib/services/cosmetic_prefs.dart
//
// Holds which cosmetic is currently SELECTED in each Hops Shop category
// (radar icon, Hopper skin, avatar frame, chat bubble skin, Wordle
// palette, username flair, notification ping sound). This is deliberately
// separate from CarrotWallet.owned (services/carrot_wallet.dart): owned is
// "what have I unlocked", this is "which unlocked one is active right
// now" — a theme/icon/etc. can be owned without being selected.
//
// Every one of these is a LOCAL rendering choice, same as the AppTheme
// picker already was before this file existed: nothing here is broadcast
// to other Hops users. That's consistent with this whole app's "no
// server-side data plane beyond identity" design (CLAUDE.md) and the
// explicit Option C decision that carrots/cosmetics stay entirely
// on-device — see CarrotWallet's header comment. The one exception is the
// Character Avatar (character_creator_page.dart, theme/avatar_icons.dart),
// which piggybacks on the existing avatar_path photo mechanism and so DOES
// reach contacts the same way an uploaded photo already does.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One instance per cosmetic category. Not a singleton map keyed by string
/// — a fixed, small number of categories is easier to follow as named
/// fields on CosmeticPrefs than a stringly-typed lookup table.
class CosmeticPrefs {
  CosmeticPrefs._();
  static final CosmeticPrefs instance = CosmeticPrefs._();

  static const _radarIconKey = 'cosmetic_radar_icon_v1';
  static const _hopperSkinKey = 'cosmetic_hopper_skin_v1';
  static const _avatarFrameKey = 'cosmetic_avatar_frame_v1';
  static const _bubbleSkinKey = 'cosmetic_bubble_skin_v1';
  static const _wordlePaletteKey = 'cosmetic_wordle_palette_v1';
  static const _flairKey = 'cosmetic_flair_v1';
  static const _pingSoundKey = 'cosmetic_ping_sound_v1';
  static const _characterBaseKey = 'cosmetic_character_base_v1';
  static const _characterTintKey = 'cosmetic_character_tint_v1';
  static const _characterAccessoryKey = 'cosmetic_character_accessory_v1';
  static const _profileBannerKey = 'cosmetic_profile_banner_v1';

  // Defaults MUST match each catalog file's free "no-op" entry id (e.g.
  // radar_icons.dart's kRadarIconDefault) — kept as plain string literals
  // here rather than importing every catalog, so this file stays a leaf
  // dependency importable from anywhere without a big import fan-out.
  final ValueNotifier<String> radarIcon = ValueNotifier<String>('radar:dot');
  final ValueNotifier<String> hopperSkin = ValueNotifier<String>('hopper:default');
  final ValueNotifier<String> avatarFrame = ValueNotifier<String>('frame:none');
  final ValueNotifier<String> bubbleSkin = ValueNotifier<String>('bubble:default');
  final ValueNotifier<String> wordlePalette = ValueNotifier<String>('wordle:classic');
  final ValueNotifier<String> flair = ValueNotifier<String>('flair:none');
  final ValueNotifier<String> pingSound = ValueNotifier<String>('sound:default');

  // The Character Creator's last-built combo (character_creator_page.dart)
  // — separate from whether it's actually your live avatar right now
  // (applying is an explicit button, not automatic on every part change),
  // so reopening the creator picks up where you left off even if
  // avatar_path has since changed to something else (a re-uploaded photo,
  // say).
  final ValueNotifier<String> characterBase = ValueNotifier<String>('avatar:bunny');
  final ValueNotifier<String> characterTint = ValueNotifier<String>('char:tint:natural');
  final ValueNotifier<String> characterAccessory = ValueNotifier<String>('char:acc:none');

  // Profile screen header banner — see theme/profile_banners.dart. Value is
  // either one of BannerOptions.all's ids or the kBannerCustom sentinel,
  // in which case the actual image lives at a separate 'custom_banner_path'
  // SharedPreferences key (same pattern as avatar_path), not here.
  final ValueNotifier<String> profileBanner = ValueNotifier<String>('banner:campus_dusk');

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    radarIcon.value = prefs.getString(_radarIconKey) ?? radarIcon.value;
    hopperSkin.value = prefs.getString(_hopperSkinKey) ?? hopperSkin.value;
    avatarFrame.value = prefs.getString(_avatarFrameKey) ?? avatarFrame.value;
    bubbleSkin.value = prefs.getString(_bubbleSkinKey) ?? bubbleSkin.value;
    wordlePalette.value = prefs.getString(_wordlePaletteKey) ?? wordlePalette.value;
    flair.value = prefs.getString(_flairKey) ?? flair.value;
    pingSound.value = prefs.getString(_pingSoundKey) ?? pingSound.value;
    characterBase.value = prefs.getString(_characterBaseKey) ?? characterBase.value;
    characterTint.value = prefs.getString(_characterTintKey) ?? characterTint.value;
    characterAccessory.value = prefs.getString(_characterAccessoryKey) ?? characterAccessory.value;
    profileBanner.value = prefs.getString(_profileBannerKey) ?? profileBanner.value;
  }

  Future<void> _set(ValueNotifier<String> notifier, String key, String id) async {
    notifier.value = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, id);
  }

  Future<void> selectRadarIcon(String id) => _set(radarIcon, _radarIconKey, id);
  Future<void> selectHopperSkin(String id) => _set(hopperSkin, _hopperSkinKey, id);
  Future<void> selectAvatarFrame(String id) => _set(avatarFrame, _avatarFrameKey, id);
  Future<void> selectBubbleSkin(String id) => _set(bubbleSkin, _bubbleSkinKey, id);
  Future<void> selectWordlePalette(String id) => _set(wordlePalette, _wordlePaletteKey, id);
  Future<void> selectFlair(String id) => _set(flair, _flairKey, id);
  Future<void> selectPingSound(String id) => _set(pingSound, _pingSoundKey, id);
  Future<void> selectCharacterBase(String id) => _set(characterBase, _characterBaseKey, id);
  Future<void> selectCharacterTint(String id) => _set(characterTint, _characterTintKey, id);
  Future<void> selectCharacterAccessory(String id) => _set(characterAccessory, _characterAccessoryKey, id);
  Future<void> selectProfileBanner(String id) => _set(profileBanner, _profileBannerKey, id);
}
