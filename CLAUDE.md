# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

- `client/` — the Flutter app (both the student app and the admin app; see "Two entry points"
  below). All Flutter/Dart tooling must be run from here.
- `supabase/` — `migrations/` (numbered SQL, `0001_…` upward) and `functions/`. This backs identity
  and moderation only — see "Identity, auth & moderation".
- `website/` — a static marketing/download site (plain HTML/CSS). No build step, unrelated to the
  app.

## Commands

Run all of these from `client/`:

```
flutter pub get                        # install dependencies
flutter run                            # student app on a connected device/emulator
flutter run -t lib/main_admin.dart     # ADMIN app (same package/APK, second Dart entry point)
flutter analyze                        # static analysis (flutter_lints, see analysis_options.yaml)
flutter test                           # run tests in test/
flutter build apk                      # Android build
flutter build windows                  # Windows desktop build
```

Note: `test/widget_test.dart` is still the unmodified default Flutter counter-app test (it
references a nonexistent `MyApp` widget) — `flutter test` currently fails out of the box. Fix or
replace this test before relying on `flutter test` for verification; don't assume test failures
here indicate a regression you caused. `flutter analyze` is the real verification gate.

`flutter analyze lib/` currently reports 3 pre-existing infos (two `anonKey` deprecations in the
two entry points, one `constant_identifier_names` on `HOPS_SERVICE_UUID`). Treat that as the
baseline, not as damage you caused.

Secrets: Supabase credentials are read from `client/.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`)
via `flutter_dotenv`; the file is gitignored but declared as a Flutter asset in `pubspec.yaml`, so
it must exist locally for the app to build/run.

## Architecture

Hops is an offline-first, BLE-mesh campus safety/social app. Three distinct Bluetooth mechanisms
are used for different purposes, plus a Supabase backend used only for identity and moderation —
there is no server-side data plane; all peer features work over local Bluetooth.

### Two entry points, one APK

`lib/main.dart` (student) and `lib/main_admin.dart` (admin) are two Dart entry points into the same
package — not separate build flavors, and there is only one `AndroidManifest.xml`. The admin app
reuses the shared identity/crypto/BLE primitives and is deliberately thinner: no sqflite, no
quick-actions shortcuts, no onboarding. It signs in against a `profiles` row with `role = 'admin'`
and never signs one up (admin accounts are provisioned out-of-band). Because the manifest is
shared, anything native added for one entry point is visible to both — but Android notification
*channel ids* must stay distinct (channels are immutable once created; `main_admin.dart` uses
`admin_foreground_service`, `main.dart` uses `foreground_service`).

### 1. BLE advertisement name as the wire protocol (main mechanism)

Most features (presence, friend requests, emergency flares, watch-buddy pairing, community/official
alerts, pairing codes, mini-games, Lost & Found, Study Bunny) do **not** use GATT reads/writes.
Instead each device repeatedly re-advertises its BLE local name with a short text prefix encoding
the event, and every other device passively scans and parses incoming advertisement names. This
lives in `lib/views/hops_app.dart` (`_HopsAppState`):

- Advertising: `ble_peripheral`, via the `_advertiseWithName(name, services)` helper — always
  includes the fixed Hops service UUID (`services/hops_constants.dart::HOPS_SERVICE_UUID`) so the
  hardware scan filter picks it up. Each advertisement is transient (a few seconds, then reverts to
  the `HPS:` beacon via `_advertisePresenceBeacon()`); route every "go back to just being present"
  call through that helper rather than re-advertising the beacon directly, or the Hops & Robbers
  runner tag and Discoverable mode get silently dropped.
- Scanning: `flutter_blue_plus`, filtered to that same service UUID in `_startContinuousScan()`,
  feeding a single `_bleScanResultsSubscription` that fans out to the radar stream (raw scan
  results for `RadarScreen`) and a big prefix-dispatch `if` chain.
- Prefixes in use: `HPS:` (idle presence beacon, carries a *rotating token*, not a username — see
  below), `EMG:`/`EMG_OFF:` (emergency flare + cancel), `ADM:`/`ADM_OFF:` (admin Official Alert,
  sent only by the admin app via `services/official_alert_service.dart`), `FR:`/`FA:` (friend
  request/accept), `WR:`/`WA:` (watch-buddy request/accept), `ACK:`/`HOP:` (manual pairing-code
  handshake), `CHT:` (chat ping — addressed to a peer by *truncated plaintext username*, not a
  rotating token, since you can't know a contact's token before a chat has ever connected),
  `TAG:`/`GAME_` (Hops & Robbers), `VBT:`/`VBX:` (Vibe
  Check tag/expiry), `LNR:` (Lost & Found resolution), `SBF:`/`SBI:`/`SBC:`/`SBX:` (Study Bunny).
  Chunked multi-part payloads have their own prefix constants in `hops_constants.dart`:
  `kCommunityChatPrefix` (`CM:`), `kAdminCommunityChatPrefix` (`CA:`), `kCommunityDeletePrefix`
  (`CX:`), `kDirectMessagePrefix` (`DM:`), `kLostFoundPrefix` (`LNF:`).
- Manufacturer data (`kCommunityManufacturerId`, `0xFFFF`) is a *second*, parallel channel riding
  the same advertisement, used where the name is already full: signature chunks for flares/alerts
  (`encodeFlareSigChunk`), watch-buddy seeds, Discoverable name, and the game runner tag. There is
  only **one** manufacturer-data slot per advertisement, so these are mutually exclusive by
  construction — check `_advertisePresenceBeacon` before adding another user of it.
- Nearby BLE device count (app-bar chip) is a *separate*, unfiltered 3-second scan
  (`_updateBleDeviceCount`) so it reflects total ambient BLE traffic, not just Hops peers.

**Advertisement size is the tightest constraint in the codebase.** The plugin puts the local name in
both the advertise payload and the scan response, and the advertise payload also carries the 128-bit
service UUID — so an over-long name fails the whole advertisement with
`ADVERTISE_FAILED_DATA_TOO_LARGE`. Payloads are truncated (8-char sender tags, 14-char reasons) for
this reason; check the `encode*`/length-clamping helpers before adding a prefix or widening a field.

**Advertising can fail silently, and does on some hardware.** `BlePeripheral.startAdvertising()`
posts to an Android `Handler` and returns immediately — a successful Dart call proves nothing. The
real verdict arrives asynchronously via `AdvertiseCallback.onStartFailure`, surfaced only through
`BlePeripheral.setAdvertisingStatusUpdateCallback` (wired to `_handleAdvertisingStatusUpdate`).
Sending also requires the BLE *peripheral* role, which central-only chipsets (common on budget and
older handsets) don't have: such a device receives everything and transmits nothing. `HopsApp`
checks `BlePeripheral.isSupported()` at startup, warns once, and refuses to attempt a flare it
can't send. **Never treat a Dart-side `startAdvertising` success as proof anything left the radio.**

### 2. Real 1:1 chat: RFCOMM over classic Bluetooth (native channel)

Actual chat sessions (not just presence blips) use classic Bluetooth RFCOMM sockets implemented
natively in Kotlin, bridged to Dart per-peer:

- `android/.../MainActivity.kt` owns a `com.example.client/rfcomm/meta` MethodChannel (adapter name
  get/set, own address, bonded devices, classic-BT discovery via `FoundDeviceReceiver` +
  EventChannel, `ensureDiscoverable`) and an `openSession`/`closeSession` handler that spins up a
  dedicated `com.example.client/rfcomm/<peerId>` MethodChannel + `RfcommChatService.kt` per
  connection.
- `lib/services/rfcomm_chat_service.dart` is the Dart-side wrapper (`startServer`,
  `connectToDevice`, `sendMessage`, `disconnect`), plus the profile exchange (`sendProfile` /
  `onProfileReceived`) that syncs a contact's avatar and bio. That exchange is the **only** way
  cosmetics cross devices — see `services/cosmetic_prefs.dart`'s header.
- Sockets are deliberately **insecure** RFCOMM on both ends. The secure variant silently kicks off
  OS-level bonding, which surfaced as an unsolicited "Pair with X?" dialog on every connection.
  Nothing here relies on bonding, so don't "fix" this back.
- `BluetoothSocket.connect()` has no built-in timeout and can hang forever on some stacks;
  `CONNECT_TIMEOUT_MS` plus a watchdog that *closes the socket* is what unblocks it (cancelling the
  coroutine does not).

### 3. Google Nearby Connections (Hops Share only)

`lib/views/hops_share_page.dart` uses `nearby_connections` (`Strategy.P2P_CLUSTER`) for file and
quick-note transfer — a third, separate mechanism. Points that are easy to get wrong:

- Every device advertises **and** discovers simultaneously, and the plugin registers connection
  callbacks *separately* for each role. Both sets fire, so a mutual "Connect" tap delivers
  `onConnectionInitiated` twice for the same peer. `acceptConnection` must be called **at most
  once** per endpoint (`_acceptedEndpoints`) — a second accept fails and takes the whole handshake
  down. All three callbacks are shared between both directions (`_handleConnectionInitiated`,
  `_handleConnectionResult`, `_handleDisconnected`); don't reintroduce per-role copies.
- `requestConnection`/`acceptConnection` return Futures that throw. The losing half of a
  simultaneous-request race throws routinely and must be caught and treated as a non-event.
- `_isConnected` is set only on `Status.CONNECTED`, never at accept time.
- Files are sent with `sendFilePayload` (streams from disk), never `sendBytesPayload` — the latter
  loads the whole file into memory and reports no incremental progress. Both directions have
  progress bars driven by `onPayloadTransferUpdate`, routed by payload id.
- Entering this screen pauses `HopsApp`'s own BLE advertising/scan timers via
  `nearbyConnectionsSessionCount` — both compete for the same radio.

### 4. Identity, auth & moderation (Supabase, custom-rolled — not Supabase Auth)

`lib/views/root_gatekeeper.dart` implements sign-up/sign-in directly against a Supabase `profiles`
table (not the Supabase Auth product): username + salted password hash (see
`0018_salted_password_hashing.sql`), plus a rotating `hops_token` session token saved to
`SharedPreferences` as `saved_hops_token`. An RSA keypair (`crypton`) is generated on
sign-up/first-sign-in, the public key is stored in `profiles`, and the private key stays in
`flutter_secure_storage` — never sent to the backend after generation. That key is what signs
Emergency Flares and Official Alerts (`services/key_directory.dart` distributes public keys).
`main.dart` decides `HopsApp` vs `HopsRootGatekeeper` purely by whether `saved_hops_token` exists;
there's no token validation at startup, only the periodic `_syncIdentityStatus` poll.

`profiles.role`, the moderation tables, and the admin action log are the only other server-side
state — feature data (messages, tasks, vibes) never leaves the device.

### 5. Local persistence

- `lib/database/database_helper.dart` — singleton `sqflite` wrapper, versioned schema
  (`_databaseVersion`, currently 10) with four tables: `messages` (mesh chat log + relay queue),
  `vibe_records`, `tasks`, `contact_profiles` (peer avatar path / bio, populated by the RFCOMM
  profile exchange). On Windows/Linux, `main.dart` swaps in `sqflite_common_ffi`. Bump
  `_databaseVersion` and add an `_onUpgrade` branch for schema changes — don't edit `_onCreate`
  alone once the app has shipped.
- `SharedPreferences` for small local state: auth token/username/avatar path, enabled feature IDs,
  watch-buddy state, theme index, carrot balance, cosmetics, Wordle progress/streaks, and one-time
  flags (`terms_accepted`, `walkthrough_seen`).

**Avatar/image files must use unique (timestamped) filenames, never a fixed path.** Flutter's
`imageCache` keys a decoded `FileImage` by path and never notices the bytes changed underneath an
unchanged path, so overwriting in place shows the *first* image forever. Both
`edit_identity_screen.dart` (own avatar) and `chat_terminal.dart` (peer avatar) write a new
timestamped file and delete the old one.

### 6. Feature system, carrots & cosmetics

`lib/models/feature_item.dart` defines a static `allFeatures` catalog of toggleable "mini-apps".
`HopsApp` persists which IDs are enabled (`enabledFeatureIds`) and renders them in the "Features"
(browse/add) and "My Features" (launch) tabs; each card either navigates via `feature.pageBuilder`
or is special-cased by `feature.id` in `hops_app.dart` when it needs data wired in (radar stream,
friend list, etc.).

Carrots (`services/carrot_wallet.dart`) are earned from Hops Hopper and Hops Wordle and spent in
the Hops Shop (`views/hops_shop_page.dart`, `services/cosmetic_prefs.dart`) on cosmetics only —
nothing gameplay- or safety-affecting. **Repeatable game modes must not pay carrots**: Hops
Wordle's Unlimited mode deliberately pays nothing and can't touch the daily streak, because an
endlessly repeatable puzzle would let anyone mint an unbounded balance. The Shop is not an addable
catalog feature; it's reached from persistent buttons on the Radar and Features tabs.

### 7. App shell & background behavior

- `main.dart` → `HopsRoot` (routes to `HopsApp` or `HopsRootGatekeeper`) → after
  auth/terms/walkthrough, `HopsApp` is the tabbed shell (Radar/Home, Contacts, Community Alerts,
  Features, My Features), each tab built inline in `hops_app.dart` except Community Alerts, which
  is a standalone widget fed the shared radar stream and is **read-only for students** — only the
  admin app composes into it.
- Tabs are driven by a `PageView` + `_pageController`, with `onPageChanged` keeping `_currentIndex`
  in sync. **Setting `_currentIndex` alone does not change the visible page** — it only moves the
  nav pill, leaving the nav bar and the screen disagreeing until the user touches something. Any
  programmatic tab change must call `_pageController.jumpToPage`/`animateToPage`. This bug has
  recurred several times; check for it first when "the nav bar says X but I'm still on Y".
- `flutter_foreground_task` + `flutter_local_notifications` keep a foreground service alive
  (`services/foreground_service.dart`, `notification_service.dart`) so BLE scanning keeps running
  in the background for emergency-flare alerts.
- Theming is data-driven: `theme/app_theme.dart` defines an `AppTheme` model and `AppThemes.all`
  catalog; the active theme index lives in a global `themeNotifier` (`main.dart`) persisted to
  `SharedPreferences`. Both entry points read it.

### 8. Emergency Flare — triggers and known limits

There is **no in-app flare button**. It is reached only from outside the UI, and all three paths
open the same confirm-then-reason dialog — none of them skips confirmation:

- Hold Volume Down for `VOLUME_HOLD_SOS_MS` (5s) while Hops is foregrounded — `MainActivity.kt`'s
  `dispatchKeyEvent`. Implemented with a delayed `Runnable`, *not* `KeyEvent.repeatCount`: hardware
  volume keys don't auto-repeat `ACTION_DOWN`, which is why the original attempt never fired. Some
  OEM skins intercept volume keys before an app sees them, so this needs on-device verification.
- The Quick Settings tile (`HopsSosTileService.kt`), delivered cold-start via `consumePendingSos`
  or warm via `onNewIntent`.
- The app-icon shortcut (`quick_actions`, `shortcutNotifier`).

The dialog lives on `HopsApp` itself (`_showFlareConfirmDialog`), not on any tab, specifically so
`Navigator.of(context)` resolves to the **root** navigator and the prompt renders over whatever
route is on top. It must not change tabs — yanking the user to Home was both disorienting and slow
in the one situation this exists for.

### 9. Concurrent alerts

Two people flaring at once is a normal case, not an edge case, and both the radio and the
notification layer are built for it now. The invariants worth preserving:

- **One advertisement slot, so relays are queued** (`_emgRelayQueue`/`_runEmgRelayQueue`), each
  payload getting its own `_kEmgRelayWindow`. Independent advertise-then-revert pairs trample each
  other: a second relay replaces the first mid-window, then the first's timer reverts to the
  presence beacon and cuts the second short.
- **Our own flare outranks relaying anyone else's** (`_ownFlareHoldsRadio`, deliberately wider than
  `_isFlareActive` — it stays true across the 5s `EMG_OFF:` stand-down window too). Nobody else can
  send our flare; theirs is already being relayed by every other device that heard it. Any new
  "revert to the presence beacon" path must check this flag, or it will silently take our own
  emergency off the air.
- **Alerts are keyed by their full advertisement string** (`EMG:<sender>:<reason>`), which is
  already unique per sender+reason and already what the receive-side dedup sets key on. Each gets
  its own notification id from `NotificationService`'s registry, so concurrent alerts stack instead
  of overwriting.
- **Stand-downs are scoped to their sender**: `EMG_OFF:`/`ADM_OFF:` call
  `cancelAlertsMatching("EMG:<sender>:")` — the trailing colon matters, or the match runs on a
  prefix of a sender tag rather than a whole one. Never call the unscoped
  `cancelEmergencyNotification()` from a stand-down path; that silences everyone's alarms. The
  unscoped form is for the in-app alarm banner only ("make it stop"), where it's correct.
- **One siren for any number of alerts** (`_ensureAlarmSounding` never restarts a player that's
  already looping) and it's stopped in exactly one place, `_syncAlarmStateAsync`, once the registry
  empties — so `isAlarmRinging`, the notifications, and the sound can't drift apart.
- **Every alert self-expires** after `_alertAutoExpiry` unless refreshed. A stand-down is a BLE
  broadcast like any other and can simply never arrive; since alerts stack now, an orphan would
  otherwise ring forever.

Sender tags are truncated to 8 characters on the wire, so two people whose usernames share those
first 8 characters can still cancel each other's alerts. That's inherent to the wire format and
can't be fixed in the notification layer.

## Working notes

- Verify with `flutter analyze` (from `client/`), against the 3-info baseline above.
- Native Kotlin changes (`MainActivity.kt`, `RfcommChatService.kt`, `HopsSosTileService.kt`) need a
  full rebuild/reinstall — hot reload and hot restart won't pick them up. Mixin/class-shape changes
  in Dart need a hot *restart*, not a reload.
- Anything touching BLE peer-to-peer, RFCOMM chat, or Hops Share can only really be confirmed on
  two physical devices. Say so plainly rather than implying a fix is verified.
