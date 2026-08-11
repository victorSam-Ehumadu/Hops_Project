# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This repo contains a single Flutter application in `client/`. There is no other project at the
repository root — always `cd client` (or pass `client` as the working dir) before running any
Flutter/Dart tooling.

## Commands

Run all of these from `client/`:

```
flutter pub get                 # install dependencies
flutter run                     # run on a connected device/emulator (Windows/Linux desktop also supported)
flutter analyze                 # static analysis (flutter_lints, see analysis_options.yaml)
flutter test                    # run tests in test/
flutter test test/widget_test.dart   # run a single test file
flutter build apk                # Android build
flutter build windows            # Windows desktop build
```

Note: `test/widget_test.dart` is still the unmodified default Flutter counter-app test (it
references a nonexistent `MyApp` widget) — `flutter test` currently fails out of the box. Fix or
replace this test before relying on `flutter test` for verification; don't assume test failures
here indicate a regression you caused.

Secrets: Supabase credentials are read from `client/.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`)
via `flutter_dotenv`; the file is gitignored but declared as a Flutter asset in `pubspec.yaml`, so
it must exist locally for the app to build/run.

## Architecture

Hops is an offline-first, BLE-mesh campus safety/social app. Two distinct Bluetooth mechanisms are
used for different purposes, plus a Supabase backend used only for identity — there is no
server-side data plane; all peer features work over local Bluetooth.

### 1. BLE advertisement name as the wire protocol (main mechanism)

Most features (presence, friend requests, emergency flares, watch-buddy pairing, community chat,
pairing codes, mini-games) do **not** use GATT reads/writes. Instead each device repeatedly
re-advertises its BLE local name (max 29 bytes) with a short text prefix encoding the event, and
every other device passively scans and parses incoming advertisement names. This all lives in
`lib/views/hops_app.dart` (`_HopsAppState`):

- Advertising: `ble_peripheral` package, via the `_advertiseWithName(name, services)` helper —
  always includes the fixed Hops service UUID (`_hopsServiceUuid` /
  `services/hops_constants.dart::HOPS_SERVICE_UUID`) so the campus BLE hardware filter picks it up.
- Scanning: `flutter_blue_plus`, filtered to that same service UUID in `_startContinuousScan()`,
  feeding a single `_bleScanResultsSubscription` that fans out to: the radar stream (raw scan
  results for `RadarScreen`), and a big prefix-dispatch `if` chain that parses events.
- Prefixes in use: `HPS:` (idle presence beacon, `username`), `EMG:`/`EMG_OFF:` (emergency flare +
  cancel), `FR:`/`FA:` (friend request/accept), `WR:`/`WA:` (watch-buddy request/accept),
  `ACK:`/`HOP:` (manual pairing-code handshake), `TAG:`/`GAME_` (Hops & Robbers minigame),
  `CM:` (Community Chat broadcast message), `VBT:` (Vibe Check crowd-density tag).
  Each advertisement is transient (advertised for a few seconds, then reverts to the `HPS:`
  beacon) and payloads are truncated to fit the 29-byte name limit — see the `_ad*`/length-clamping
  helpers before adding new prefixes.
- Nearby BLE device count (shown in the app bar) is a *separate*, unfiltered 3-second scan
  (`_updateBleDeviceCount`) so it reflects total ambient BLE traffic, not just Hops peers.

### 2. Real 1:1 chat: RFCOMM over classic Bluetooth (native channel)

Actual chat sessions (not just presence blips) use classic Bluetooth RFCOMM sockets implemented
natively in Kotlin, bridged to Dart per-peer:

- `android/.../MainActivity.kt` owns a `com.example.client/rfcomm/meta` MethodChannel (adapter
  name get/set, bonded devices, classic-BT discovery via `FoundDeviceReceiver` + EventChannel) and
  an `openSession`/`closeSession` handler that spins up a dedicated
  `com.example.client/rfcomm/<peerId>` MethodChannel + `RfcommChatService.kt` per connection.
- `lib/services/rfcomm_chat_service.dart` is the Dart-side wrapper for that per-peer channel
  (`startServer`, `connectToDevice`, `sendMessage`, `disconnect`).
- `lib/services/chat_connection_service.dart` is a second, `nearby_connections`-based P2P chat
  implementation (Google Nearby Connections, own length-prefixed byte protocol). It appears to be
  an earlier/alternate approach — currently commented out of `hops_app.dart`'s imports — so check
  whether it's live before extending it.

### 3. Identity & auth (Supabase, custom-rolled — not Supabase Auth)

`lib/views/root_gatekeeper.dart` implements sign-up/sign-in directly against a Supabase `profiles`
table (not the Supabase Auth product): username + SHA-256 password hash, plus a rotating
`hops_token` session token (UUID, 24h expiry) saved to `SharedPreferences` as `saved_hops_token`.
An RSA keypair (`crypton`) is generated on sign-up/first-sign-in, the public key is stored in
`profiles`, and the private key is kept locally in `flutter_secure_storage` — it's never sent to
the backend after generation. `main.dart` decides `HopsApp` vs `HopsRootGatekeeper` purely by
whether `saved_hops_token` exists in `SharedPreferences`; there's no token validation against
Supabase at startup.

### 4. Local persistence

- `lib/database/database_helper.dart` — singleton `sqflite` wrapper, versioned schema
  (`_onCreate`/`_onUpgrade`) with three tables: `messages` (mesh chat log + relay queue —
  `needs_relay`/`is_for_me` support future store-and-forward relaying), `vibe_records` (Vibe Check
  history), `tasks` (offline Task Tracker). On Windows/Linux, `main.dart` swaps in
  `sqflite_common_ffi` (`databaseFactoryFfi`) since plain `sqflite` is mobile-only.
  Bump `_databaseVersion` and add an `_onUpgrade` branch for schema changes — don't edit
  `_onCreate` alone once the app has shipped.
- `SharedPreferences` is used pervasively for small local state: auth token/username/avatar path,
  enabled feature IDs, watch-buddy state, theme index, and one-time flags (`terms_accepted`,
  `walkthrough_seen`).

### 5. Feature system

`lib/models/feature_item.dart` defines a static `allFeatures` catalog of toggleable "mini-apps"
(Watch Me, Vibe Check, Task Tracker, Hops Share, ...). `HopsApp` persists which IDs are enabled
(`enabledFeatureIds`, saved to `SharedPreferences`) and renders them in the "Features" (browse/add)
and "My Features" (launch) tabs; each card either navigates via `feature.pageBuilder` or is
special-cased by `feature.id` in `hops_app.dart` when it needs data wired in (radar stream, friend
list, etc.) rather than being self-contained.

### 6. App shell & background behavior

- `main.dart` → `HopsRoot` (routes to `HopsApp` or `HopsRootGatekeeper`) → after
  auth/terms/walkthrough, `HopsApp` is the tabbed shell (Radar, Contacts, Community, Features, My
  Features), each tab built inline in `hops_app.dart` except Community Chat which is a standalone
  widget fed the shared radar stream.
- `flutter_foreground_task` + `flutter_local_notifications` keep a foreground service alive
  (`services/foreground_service.dart`, `notification_service.dart`) so BLE scanning keeps running
  in the background for emergency-flare alerts.
- Theming is data-driven: `theme/app_theme.dart` defines an `AppTheme` model and `AppThemes.all`
  catalog; the active theme index lives in a global `themeNotifier` (`main.dart`) persisted to
  `SharedPreferences` and changeable from `views/theme_picker_screen.dart`.
