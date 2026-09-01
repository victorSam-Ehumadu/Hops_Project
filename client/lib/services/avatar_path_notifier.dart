// lib/services/avatar_path_notifier.dart
//
// Bumped by every call site that writes (or clears) the 'avatar_path'
// SharedPreferences key — edit_identity_screen.dart's _pickAvatar/
// _removeAvatar, avatar_icons.dart's applyCharacterAvatar,
// account_management_screen.dart's account wipe.
//
// Why this needs to exist: several screens cache avatar_path in their own
// State rather than re-reading SharedPreferences on every build (radar_
// screen.dart's _myAvatarPath, hops_app.dart's own copy), and — unlike a
// freshly-pushed route — a screen that's already alive underneath a tab
// switch or a covering route never gets a natural "reload" moment when the
// avatar changes elsewhere. hops_app.dart mostly self-heals today via
// .then() callbacks on the specific routes that can change it, but that's
// ad hoc and easy to miss a spot (which is exactly what happened: the
// radar screen's own "you are here" marker kept showing the old avatar
// after an edit, since nothing ever told it to reload). Screens that care
// listen to this instead.
import 'package:flutter/foundation.dart';

final ValueNotifier<int> avatarPathRevision = ValueNotifier<int>(0);
