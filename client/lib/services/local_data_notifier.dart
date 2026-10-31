// lib/services/local_data_notifier.dart
//
// Bumped when the local sqlite database is changed wholesale from outside
// the screen that normally owns those rows — currently only
// account_management_screen.dart's Import My Data.
//
// Why this needs to exist: HopsApp caches the contacts tray in its own
// State (localActiveContacts, built by _refreshContactsTrayList) rather
// than re-querying on every build. Account Management is a route pushed
// over the top of it, so HopsApp is still mounted and holding that list
// the whole time an import runs — and, not having been rebuilt, never gets
// a natural reload moment afterwards. Without this, restored
// conversations simply do not appear until something unrelated happens to
// refresh the tray, which reads as the import having silently done
// nothing.
//
// Same pattern and same reasoning as avatar_path_notifier.dart; kept
// separate because they answer different questions ("the avatar changed"
// vs "the rows underneath you changed") and a screen usually cares about
// one and not the other.
import 'package:flutter/foundation.dart';

final ValueNotifier<int> localDataRevision = ValueNotifier<int>(0);
