# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

- `client/` — the Flutter app (both the student app and the admin app; see "Two entry points"
  below). All Flutter/Dart tooling must be run from here.
- `supabase/` — `migrations/` (numbered SQL, `0001_…` upward) and `functions/`. This backs identity
  and moderation only — see "Identity, auth & moderation".
- `website/` — a static marketing/download site (plain HTML/CSS). No build step, unrelated to the
  app.
- `scripts/` — PowerShell operational scripts (currently database backup/restore; see "Database
  backups" below). Not part of any build.
- `docs/` — academic project documentation and presentation material, written against the module
  guidelines PDF that also lives there. Report prose and speaker material, not developer docs —
  this file remains the developer guide. Current contents:
  - `Group 18 Phase 2.docx` (Planning) and `IT PROJECT PHASE 3 DRAFT.docx` (Analysis) — submitted.
  - `Group 18 Phase 4.docx` (System Design, 33 pp, 9 figures) and `Group 18 Phase 5.docx`
    (Implementation, 183 pp — 22 of report plus a 161-page source-code appendix of 26 files).
  - `report-4.8-security-and-backup-design.md` and `report-5.2-languages-and-tools.md` — the
    sources of record for §4.8 and §5.2, rendered into those documents at build time. Edit the
    markdown, not the Word copy, or the two drift.
  - `Group 18 Presentation.pptx` — the 38-slide deck, 14 segments across 7 presenters, with the
    full speaker script in each slide's notes pane. Dark ground throughout: the palette is the
    app's own Hops Default theme *inverted* (`#002020` becomes the background, `#e2fffe` the
    text), because a near-white slide in a darkened room is painful and wrecks night vision for
    the live demo. Eight images — seven diagrams plus the logo — are generated, not drawn by
    hand; keep them transparent-background and light-ink or they will sit in a pale box.
  - `Group 18 Presentation Practice Pack.docx` — the companion: running order, per-member pages,
    question bank, pre-flight checklist, demo-failure wording, and the table of figures anyone is
    allowed to quote on stage.
  - `Hops User Testing Part 1.csv` — 13 respondents, 54 rated items, collected 11 Aug 2026 on an
    earlier build. Feeds Phase 5 §5.4 as the acceptance-testing evaluation.
  - `backup-demo-runbook.md` — running the restore verification as a live demonstration.

  Both presentation files are **generated** — see `docs/generators/` and its README.
  `python docs/generators/build_deck.py` and `build_pack.py` rebuild them; content lives as data
  in `deck_content.py` / `pack_content.py`, layout in the build scripts, figures in `assets/`.
  An edit made directly in PowerPoint or Word exists only in that file, so pull it back with
  `extract_from_pptx.py` / `extract_from_docx.py` **before** the next build or it is discarded.
  Every figure in them is counted from this repository — if a count here changes, section 7 of
  the practice pack and the numbers slide in the deck both go stale.

  These generators previously lived outside the repo and were lost when that directory was
  cleared, leaving no way to rebuild the deck. They were reconstructed by reading the committed
  files back out. Keep them in the repo.
- `backups/` — gitignored `pg_dump` output. Never commit anything from here.

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

`flutter test` passes: **125 tests**, all green. The default counter-app `widget_test.dart` that
used to break the run has been deleted. Treat a failure as a real regression.

What is and isn't covered, so you know what a green run actually proves:

- `test/services/hops_constants_test.dart` (57) — the advertisement wire format: budget
  arithmetic, community/DM chunk encode/decode round trips, `splitCommunityMessage` (including
  never splitting a multi-byte character across chunks), rotating presence tokens and their
  window-rollover tolerance, flare signature chunking reassembled at full RSA-2048 length. This is
  the highest-value file in the suite — it pins the tightest constraint in the codebase and is
  pure Dart with no plugins.
- `test/utils/password_policy_test.dart` (27) — username/email/password rules and strength
  scoring. The blocklist tests guard two things that are easy to undo: the blocklist is checked
  **before** the character-class rules (below them it is unreachable, since every entry is
  lowercase letters and digits and fails the uppercase rule first), and it compares a *folded*
  form — case dropped, non-alphanumerics stripped, `0/1/3/4/5/7/@/$/!` mapped back to letters —
  by substring, so `Password123!` and `P@ssw0rd1` are caught. One test guards the other side of
  that trade, checking ordinary strong passwords aren't over-blocked.
- `test/services/carrot_wallet_test.dart` (13) — balance, purchases, and the
  `debugUnlimitedCarrots` flag. Reads the flag through a function call, not directly, so both
  branches stay live and the tests survive the flag being flipped for launch.
- `test/services/bluetooth_name_guard_test.dart` (8) — the payload-name detector. Includes a test
  asserting the prefix list covers every prefix `hops_app.dart` dispatches on; add to both when you
  add a prefix, or the new one gets mistaken for a user's real Bluetooth name. Conversely, when a
  prefix is *removed*, drop it from the guard, this test's expected list, and any literal payload
  assertion that used it — removing Hops & Robbers needed all three.
- `test/widgets/password_strength_bar_test.dart` (10) — the only widget test.
- `test/services/accessibility_prefs_test.dart` (7) — the behaviour toggles. Pins that every
  one defaults **off** (`speakWatchMeAlerts` says a contact's name aloud, so a default flip
  would be a privacy regression nothing else would catch) and that the two speech toggles
  are independent — asking for chat messages read aloud must not also start announcing
  Watch Me.
- `test/views/flare_radio_invariant_test.dart` (3) — a *source-level* guard, not a
  behavioural test: it reads `hops_app.dart` as text and fails if any revert-to-beacon path
  bypasses `_releaseRadioToPresenceBeacon()`, or if a guard checks `_isFlareActive` without
  also checking `_ownFlareHoldsRadio`. Added because this bug class had already recurred and
  is otherwise only reachable with two physical devices — see "Concurrent alerts" below.

Not covered, and the obvious next target: `database_helper.dart`. It calls
`getApplicationDocumentsDirectory()`, so testing it needs path_provider channel mocking plus
`sqflite_common_ffi` and a native sqlite3 on Windows. Nothing BLE, RFCOMM or Nearby is covered —
those need two physical devices, and no test suite will change that.

`flutter analyze` is still the primary gate for anything radio-related.

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
  the `HPS:` beacon via `_advertisePresenceBeacon()`). Route every "go back to just being present"
  call through `_releaseRadioToPresenceBeacon()` — it owns both the Discoverable-mode attachment
  and the flare guard; see "Concurrent alerts".
- Scanning: `flutter_blue_plus`, filtered to that same service UUID in `_startContinuousScan()`,
  feeding a single `_bleScanResultsSubscription` that fans out to the radar stream (raw scan
  results for `RadarScreen`) and a big prefix-dispatch `if` chain.
- Prefixes in use: `HPS:` (idle presence beacon, carries a *rotating token*, not a username — see
  below), `EMG:`/`EMG_OFF:` (emergency flare + cancel), `ADM:`/`ADM_OFF:` (admin Official Alert,
  sent only by the admin app via `services/official_alert_service.dart`), `FR:`/`FA:` (friend
  request/accept), `WR:`/`WA:` (watch-buddy request/accept), `ACK:`/`HOP:` (manual pairing-code
  handshake), `CHT:` (chat ping — addressed to a peer by *truncated plaintext username*, not a
  rotating token, since you can't know a contact's token before a chat has ever connected),
  `VBT:`/`VBX:` (Vibe Check tag/expiry), `LNR:` (Lost & Found resolution),
  `SBF:`/`SBI:`/`SBC:`/`SBX:` (Study Bunny).
  Chunked multi-part payloads have their own prefix constants in `hops_constants.dart`:
  `kCommunityChatPrefix` (`CM:`), `kAdminCommunityChatPrefix` (`CA:`), `kCommunityDeletePrefix`
  (`CX:`), `kDirectMessagePrefix` (`DM:`), `kLostFoundPrefix` (`LNF:`).
- Manufacturer data (`kCommunityManufacturerId`, `0xFFFF`) is a *second*, parallel channel riding
  the same advertisement, used where the name is already full: signature chunks for flares/alerts
  (`encodeFlareSigChunk`), watch-buddy seeds, and the Discoverable name. There is
  only **one** manufacturer-data slot per advertisement, so these are mutually exclusive by
  construction — check `_advertisePresenceBeacon` before adding another user of it.
- Nearby BLE device count (app-bar chip) is a *separate*, unfiltered 3-second scan
  (`_updateBleDeviceCount`) so it reflects total ambient BLE traffic, not just Hops peers.

**Advertisement size is the tightest constraint in the codebase.** The plugin puts the local name in
both the advertise payload and the scan response, and the advertise payload also carries the 128-bit
service UUID — so an over-long name fails the whole advertisement with
`ADVERTISE_FAILED_DATA_TOO_LARGE`. Payloads are truncated (8-char sender tags, 14-char reasons) for
this reason; check the `encode*`/length-clamping helpers before adding a prefix or widening a field.

**The advertised name IS the device's system Bluetooth name.** `ble_peripheral` has no separate
BLE local-name field: `BlePeripheralPlugin.kt` does `adapter?.name = it` and then
`.setIncludeDeviceName(localName != null)`. So advertising `CHT:diya:Test2` literally renames the
phone to that, and every nearby device shows it in Bluetooth settings — and caches it in the paired
list if a bond exists. `services/bluetooth_name_guard.dart` owns the cleanup and must be the only
thing that reads or writes the adapter name:

- It **persists** the real name to `SharedPreferences`, because the case that breaks an in-memory
  copy is the app being killed mid-advertisement.
- It **refuses to record a payload string as the original** (`looksLikeHopsAdvertisementName`).
  Without that check the startup capture reads `HPS:xk3f9a2b` off the adapter, saves it as the
  "original", and every later restore faithfully writes a protocol string back — the cleanup
  mechanism becomes what keeps it dirty.
- `restore()` is called from `_advertiseWithName` (500ms later — the payload is already baked into
  the running advertisement, so this doesn't disturb what peers receive), from
  `_handleAppBackgrounded`, from `dispose()`, and at startup. `stopAdvertising()` does **not** undo
  the rename; any new path that stops advertising must call `restore()` too.

What this cannot fix: while an advertisement is on the air the name is the protocol, so it is
visible then by construction. Removing that entirely means moving payloads off the name.

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

### 4b. Runtime permissions — always version-gated

**Never request `Permission.bluetoothScan` / `bluetoothAdvertise` / `bluetoothConnect`
unconditionally.** Those exist only from Android 12 (API 31). Below that, `permission_handler`
resolves them to *no manifest entry* (`PermissionUtils.java:283` gates on `SDK_INT >= S`) and
`PermissionManager.java:369` records any permission with no manifest entry as **denied**. So on an
Android 8/9 handset they come back denied with no dialog shown and nothing in system settings the
user can switch on — an unclearable state.

Every gate that required them was therefore permanently locked on pre-12 devices: sign-in failed
with "Err: Permissions Denied", `HopsApp` bounced straight back to the gatekeeper on launch, Hops
Share stuck on its prompt, and 1:1 chat reported "Bluetooth & location permission needed" without
ever calling `connect()` — which read as a Bluetooth pairing problem and was not one.

`services/bluetooth_permissions.dart` is the only correct way to ask. It reads the API level over
the `getSdkInt` meta-channel call and requests location always, the Bluetooth trio only on 31+, and
`nearbyWifiDevices` only on 33+ and only for Nearby Connections callers. An unknown version is
treated as modern, since over-asking is recoverable by the user and under-asking is not.

Callers: `root_gatekeeper.dart`, `hops_app.dart`, `chat_terminal.dart`, `hops_share_page.dart`, and
all three admin screens (`admin_shell.dart`, `admin_sign_in_screen.dart`,
`admin_settings_screen.dart`). The admin screens used to request the raw Android-12 set directly,
which locked a pre-12 admin device out of the BLE hub permanently; they were migrated 10 Oct 2026.
`requestStatuses()` is the variant for callers that must tell a permanent denial from an ordinary
one — `admin_settings_screen.dart` needs it to decide whether to offer `openAppSettings()`.

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

**The avatar picker is the only camera path in the app, and the manifest must stay free of
`android.permission.CAMERA`.** `image_picker`'s `ImageSource.camera` fires the system camera app
via `ACTION_IMAGE_CAPTURE`, which needs no permission — *unless* the app declares CAMERA, in which
case Android requires it granted and throws `SecurityException` otherwise. The plugin mirrors that
rule exactly: `ImagePickerUtils.needRequestCameraPermission()` returns true only when the
permission is present in the manifest. So declaring it would add a runtime prompt and a failure
mode while buying nothing. Everything else that picks an image — the profile banner in
`theme/profile_banners.dart` — is `ImageSource.gallery` only.

### 5b. The offline assistant (`services/hops_engine.dart`)

`HopsEngine` is a singleton holding two unrelated subsystems that share a load-once lifecycle:

- **`askBunny(query)`** — keyword lookup over `assets/data/hops_knowledge.json` (62
  `{keywords, response}` entries). This is what backs the built-in contact named `Hops`
  (`kHopsBotUsername`), which every user has from first launch; `chat_terminal.dart` routes
  messages to that peer here instead of over the radio. Bot history lives in the same local
  `messages` table keyed by peer username, which is why sign-up reserves the bot usernames —
  a real account holding one would interleave with the bot's own messages.
- **`getSmartRouteScore(rssi, battery)`** — ranks candidate relay neighbours. Consults an
  optional TFLite model and falls back to a heuristic; **a missing model file is an expected
  state, not an error.**

Optional text-to-speech (`flutter_tts`) lives here and is the app's **only** TTS engine —
anything that needs to speak calls `bunnyTalk()` rather than opening a second `flutter_tts`
instance. Three callers, each behind its own opt-in toggle in `accessibility_prefs.dart`
(that file is for toggles that change *behaviour*, as distinct from `cosmetic_prefs.dart`,
which is appearance only):

- the assistant's own replies, in `chat_terminal.dart`;
- incoming 1:1 chat messages, gated by `readMessagesAloud`;
- Watch Me status changes, gated by `speakWatchMeAlerts` — see `watch_me_page.dart`'s
  `_announce()`, which also refuses to speak while `NotificationService.isAlarmRinging` is
  true. A flare siren is engineered to be impossible to ignore; talking across it degrades
  the one sound in this app that has to cut through, and a Watch Me update is never the more
  urgent of the two. **Any new speech call site should go through a helper with that same
  guard, not straight to `bunnyTalk()`.**

**There is no LLM path and there must not be one added casually.** The header comment records a
removed attempt to load `gemma-2b-it.bin` via `Interpreter.fromAsset`: tflite_flutter reads
`.tflite` FlatBuffers (a Gemma `.bin` is MediaPipe/GGUF), `Interpreter.run()` takes numeric
tensors rather than prompt strings, and a ~2GB asset blows the 200MB base-module limit. It was
removed rather than stubbed so nothing pretends to be an LLM — keep it that way.

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
- `flutter_foreground_task` + `flutter_local_notifications` keep a foreground service alive so BLE
  scanning keeps running in the background for emergency-flare alerts. The service is configured
  and started **inline in `main.dart` / `main_admin.dart`**; `notification_service.dart` owns the
  alert registry. Note `services/foreground_service.dart` is **dead code** — nothing imports it,
  and its `MyTaskHandler` is never registered. The only thing matching `foreground_service`
  elsewhere is the notification *channel id* string, which is unrelated. Same for
  `views/half_wheel.dart`. Delete both or wire them up; don't assume they run.
- Theming is data-driven: `theme/app_theme.dart` defines an `AppTheme` model and `AppThemes.all`
  catalog; the active theme index lives in a global `themeNotifier` (`main.dart`) persisted to
  `SharedPreferences`. Both entry points read it.

### 8. Emergency Flare — triggers and known limits

There is **no in-app flare button**. It is reached only from outside the UI, and both remaining
paths open the same confirm-then-reason dialog — neither skips confirmation:

- The Quick Settings tile (`HopsSosTileService.kt`), delivered cold-start via `consumePendingSos`
  or warm via `onNewIntent`.
- The app-icon shortcut (`quick_actions`, `shortcutNotifier`).

**The volume-down hold trigger was removed**, along with the Silent SOS settings page and its
Profile entry. It worked on some handsets and silently did nothing on others, because OEM skins
intercept volume keys before `dispatchKeyEvent` ever sees them — the worst possible property for a
safety feature, since it teaches a gesture the user then trusts. Don't reintroduce it without a way
to verify at runtime that the key is actually reaching the app. The tile is still added from
Android's own Quick Settings edit panel; nothing in-app requests it any more.

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
  send our flare; theirs is already being relayed by every other device that heard it.
  **Never hand the advertisement slot back by hand.** `_releaseRadioToPresenceBeacon()` owns the
  `_isFlareActive || _ownFlareHoldsRadio` check and is the only correct way to revert from a
  transient advertisement; a hand-rolled `stopAdvertising()` + `_advertisePresenceBeacon()` pair
  silently takes our own emergency off the air when its timer happens to fire mid-flare, and the UI
  goes on showing an active flare with a running countdown. `test/views/flare_radio_invariant_test.dart`
  fails the build if a new one appears. Guards that re-advertise the beacon must check **both**
  flags: `_isFlareActive` alone goes false the moment the flare is cancelled, while the stand-down
  is still broadcasting.
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

## Database backups

The Supabase database is the only state that doesn't live on a device, so it's the only thing
that needs backing up. Two PowerShell scripts, run from the repo root:

```
powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1           # take a dump
powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1 -Masked   # same, URI input hidden (projector)
powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1       # restore it locally to prove it works
powershell -ExecutionPolicy Bypass -File .\scripts\reset-local-pg-password.ps1   # ELEVATED; forgot the local postgres password
```

`-ExecutionPolicy Bypass` is required — the machine default is Restricted. It scopes to that one
invocation.

Last verified restore: **1 Sep 2026**, 8/8 tables and 67/67 rows into a local scratch database.
`verify-backup.ps1` never contacts the cloud database and needs no network, so it is safe to run
anywhere — including as a live demonstration (see `docs/backup-demo-runbook.md`).

Things that are non-obvious and cost time to rediscover:

- **`pg_dump` is not on PATH.** The EDB installer doesn't add its `bin` directory, so the command
  doesn't exist after a successful install. Both scripts resolve the binary themselves out of
  `C:\Program Files\PostgreSQL\<ver>\bin`, highest major version first.
- **Use the Session pooler, not Direct connection, and never the Transaction pooler.** The direct
  host publishes an **AAAA record only** — on an IPv4 network it fails with "could not translate
  host name", which looks like a typo and isn't. The transaction pooler can hand `pg_dump` a
  different backend mid-dump, breaking the single repeatable-read snapshot it relies on and
  producing an inconsistent file. Session pooler is port 5432, user `postgres.<project-ref>`.
- **The connection URI is read via `Read-Host`, never passed as an argument.** PowerShell writes
  every typed command to `ConsoleHost_history.txt` in plaintext permanently, and that URI carries
  the database password. Don't "simplify" this into a parameter. The default prompt *echoes* what
  is pasted, which is useful for diagnosing a bad paste but wrong on a projector — hence `-Masked`.
- **Don't set `$ErrorActionPreference = "Stop"` in a script that redirects a native program's
  stderr.** Windows PowerShell 5.1 wraps each stderr line in an ErrorRecord (`NativeCommandError`),
  so under `Stop` a harmless `NOTICE: database does not exist, skipping` from `dropdb --if-exists`
  becomes a *terminating* error and aborts the run before the next command. `verify-backup.ps1`
  uses `Continue` and checks `$LASTEXITCODE` explicitly; `reset-local-pg-password.ps1` keeps `Stop`
  (it guards the `pg_hba.conf` copy) and scopes `Continue` around its one redirected call.
- **Verify the completion marker across the last ~10 lines, not the last 3.** `pg_dump` 17.6+
  emits a trailing `\unrestrict <token>` line *after* `-- PostgreSQL database dump complete`, so a
  narrow tail window misses the marker on a perfectly good dump. Also test with `-match`, not
  `-notmatch`: against an array `-notmatch` returns the non-matching *elements*, which is truthy
  whenever any single line differs.
- **`backups/` is gitignored**, deliberately as a folder rather than a `*.sql` rule — the latter
  would also swallow `supabase/migrations/`. A dump holds every row in the cloud database
  including password hashes and the full moderation log.

Current shape of the backend, useful for sanity-checking a dump: 8 tables, all with RLS enabled
and **zero policies** (deny-all by design — everything goes through 65 `SECURITY DEFINER`
functions), 74 `REVOKE`s, 61 `GRANT EXECUTE`s. If a dump comes back with policies in it, something
changed.

The reasoning behind all of this is written up for the report in
`docs/report-4.8-security-and-backup-design.md`; keep the two in sync if the procedure changes.

## Working notes

- Verify with `flutter analyze` (from `client/`), against the 3-info baseline above.
- **Keep this file current as part of the change, not afterwards.** When a change alters the
  repository layout, the verification story (test counts, the analyze baseline), a wire-format
  constraint, or an operational procedure, update the relevant section here in the same commit.
  The sections most likely to go stale are Commands (test counts and the analyze baseline) and
  Database backups.
- Native Kotlin changes (`MainActivity.kt`, `RfcommChatService.kt`, `HopsSosTileService.kt`) need a
  full rebuild/reinstall — hot reload and hot restart won't pick them up. Mixin/class-shape changes
  in Dart need a hot *restart*, not a reload.
- Anything touching BLE peer-to-peer, RFCOMM chat, or Hops Share can only really be confirmed on
  two physical devices. Say so plainly rather than implying a fix is verified.
