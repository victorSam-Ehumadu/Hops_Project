# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

- `client/` — the Flutter app (both the student app and the admin app; see "Two entry points"
  below). All Flutter/Dart tooling must be run from here.
- `supabase/` — `migrations/` (numbered SQL, `0001_…` upward) and `functions/`. This backs identity
  and moderation only — see "Identity, auth & moderation". Migrations are applied **by hand** in
  the SQL editor, so nothing records what went in; `check-applied-migrations.sql` is a read-only
  probe that reports which ones are actually live. Run it before trusting any server-side
  feature — a missing migration has already been mistaken for an app bug more than once.
- `website/` — the static marketing/download site at `hopsapp.me` (plain HTML/CSS, no build step,
  unrelated to the app's code). Six pages share the single `styles.css`, so **a class renamed
  there fails silently on whichever page you didn't open** — grep before renaming.
  `privacy.html` is the POPIA/GDPR privacy notice, linked from every footer and called out in a
  note box on `download.html`; it still carries a `TODO` for the real information officer name
  and mailbox, which must be filled in before real users (a policy naming an unreachable
  contact is worse than none). Three things
  that are easy to break:
  - **Dark mode is token-only.** `:root` and the `prefers-color-scheme: dark` block define
    colours; components must reference tokens and never hardcode one, or they look right in light
    and wrong in dark with nothing to warn you. The one deliberate exception is `.cta-band`, which
    pins its own gradient and white text — built from tokens it inverted into a light-to-dark ramp
    that no single text colour sits on legibly.
  - **`assets/hops_logo.png` must keep its alpha.** The site's copy had been flattened onto a
    white disc, invisible on the old light theme and an obvious white blob the moment a dark
    background existed. It is now the transparent original from `docs/generators/assets/`.
  - **`shop.html` is DEMO MODE.** It simulates a donation, collects no card details, and its red
    banner must stay until a real provider is wired up — see the comment block at the top of the
    file and `website/README.md`. Amounts are in **rands** (R20/R50/R100, R10–R10 000).
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
  - `Project_Hops_-_Group_18_Engineering_Deck_v2.pptx` — the **5-minute** deck, a separate
    deliverable from the 38-slide one above and **not** produced by `docs/generators/`:
    it exists only as the `.pptx`, so edit it there. Seven slides: cover, what it is, why we
    built it, tech stack, how the live demo is set up (three phones — two students, one admin —
    starting from `hopsapp.me`), questions, and a full-bleed outro video. It was ten,
    and four of those were one idea told four times — the "what it is" statement lines, a
    "Hops in One Breath" card trio and a combined what-and-why slide all made the same claim and
    two of them closed on the same three pills. **Don't re-add a slide that restates slide 2**;
    if something needs saying twice it belongs in the speaker notes, which is where the cut
    material went (the three Bluetooth mechanisms are held in slide 4's notes for questions).
    House tokens, if you add a slide: background
    inherited from the `HOPS_DARK` layout, accent `#2FD6A3`, body `#FFFFFF`/muted `#A9B8CC`,
    cards `#1B2E47` on a `#3B5273` edge, titles Cambria 45.33pt bold, eyebrows Calibri 16pt bold
    `spc="400"`. The footer and the corner watermark live on the **layout**, not on the slides,
    so a new slide gets both free by using `HOPS_DARK` — but the slide-number placeholder is
    per-slide in this deck and has to be copied from a neighbour. Transitions and the
    click-reveal timings are raw OOXML (`<p:transition>`, `<p:timing>`), which python-pptx cannot
    express; every `spid` in a timing tree **must** name a shape that exists on that slide, or
    PowerPoint silently repairs the file and drops all of its animation. Two traps when writing
    that XML: **python-pptx renumbers slide parts on save**, so the partname a slide reports in
    memory is not the name its XML ends up under — do every python-pptx save *first*, the raw-XML
    pass *last*, and find the target part by searching its XML for the title text rather than
    trusting a partname (writing to "the part python-pptx just called slide5" landed a slide's
    animation on its neighbour). And the outro video's timing is **not** an entrance: it holds
    `playFrom(0.0)`, a `togglePause` interactive sequence and a `<p:video>` media node, so a
    blanket `re.sub` over `<p:timing>` stops the video playing at all. The cover and the outro
    are the two slides deliberately off `HOPS_DARK` — the cover carries the full-colour logo
    instead of the watermark, and the outro is full-bleed with no chrome over it. Speaker notes
    carry a per-slide time budget summing to exactly 5:00, with the live demo and Q&A outside it;
    re-time the rest if any one slide changes.
  - `Group 18 Presentation Practice Pack.docx` — the companion: running order, per-member pages,
    question bank, pre-flight checklist, demo-failure wording, and the table of figures anyone is
    allowed to quote on stage.
  - `Hops User Testing Part 1.csv` — 13 respondents, 54 rated items, collected 11 Aug 2026 on an
    earlier build. Feeds Phase 5 §5.4 as the acceptance-testing evaluation.
  - `report-rfcomm-wifi-dependency.md` — why the *first* 1:1 chat connection to a contact
    needs Wi-Fi switched on, and why that does not contradict the offline claim. Source of
    record for the in-app hint and for the viva answer.
  - `action-checklist.md` — the running list of outstanding operational tasks: which
    migrations are unapplied, domain/DNS steps, two-device testing, and the flags that must be
    flipped before real users (test-email allowlist, `debugUnlimitedCarrots`, `0009`'s email
    relaxation). Keep it current as items are done.
  - `deployment-domain-and-backup.md` — DNS setup for the `hopsapp.me` sender (Resend; was
    SendGrid until its trial expired — see `supabase/functions/README.md`), and
    what "a backup of the app" should actually mean (Vercel is the wrong tool for an APK;
    tagged GitHub Releases plus a kept copy of the gitignored `client/.env` are the gap).
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

`flutter test` passes: **367 tests**, all green. The default counter-app `widget_test.dart` that
used to break the run has been deleted. Treat a failure as a real regression.

What is and isn't covered, so you know what a green run actually proves:

- `test/services/hops_constants_test.dart` (59) — the advertisement wire format: budget
  arithmetic, community/DM chunk encode/decode round trips, `splitCommunityMessage` (including
  never splitting a multi-byte character across chunks), rotating presence tokens and their
  window-rollover tolerance, flare signature chunking reassembled at full RSA-2048 length. This is
  the highest-value file in the suite — it pins the tightest constraint in the codebase and is
  pure Dart with no plugins.
- `test/utils/password_policy_test.dart` (35) — username/email/password rules and strength
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
- `test/services/advertisement_budget_test.dart` (22) — the advertisement-name byte budget
  and each feature's framing arithmetic against it. This is the exact thing that drifted and
  silently broke Vibe Check and Study Bunny on real devices: both set their input `maxLength`
  to a number that looked like the budget but ignored their own prefix/id framing, producing
  names over the 26-byte ceiling that the radio then rejected **asynchronously** — so the send
  looked successful and the report appeared locally while never leaving the phone. Pins the
  ceiling, that measurement is in UTF-8 *bytes* (a char-based check allows roughly double), and
  that each feature's budget leaves room for its own framing. One test documents the broken
  limits so nobody restores them. Lost & Found was the **third** feature to hand-write
  this number: `kLostFoundChunkTextBudget` was `29 - overhead` = 19, and 29 is not the
  ceiling, so a full chunk was a 29-byte name against the 26-byte limit and every post
  long enough to fill one chunk silently failed to send. It is now derived from
  `kCommunityNameBudget` (22), not 26 — deriving from the theoretical ceiling fixes the
  arithmetic but still would not send on the handset that reported a 23-byte real ceiling.
- `test/services/admin_stats_test.dart` (18) — the statistics window arithmetic and CSV
  export. Pins the boundary bug worth preventing: a custom range must include the *whole* of
  its end day, since treating the picked date as midnight silently drops a day and the chart
  still looks plausible. Also that no preset window ends in the future (empty trailing buckets
  read as a collapse to zero), the hour/day bucket switch, and RFC 4180 quoting — a label or
  username containing a comma would otherwise shift every later column.
- `test/services/study_location_test.dart` (12) — the Study Bunny location code. Mostly
  guarding one thing: the location travels as a one-byte **index** into `kStudyLocations`, so
  that list's order *is* wire format. Reordering or removing an entry relabels every tag in
  flight with no error anywhere — someone in the Library shows as being in a lab. Tests pin
  the order itself (not just membership, which a reorder would survive), the marker byte, and
  that an unknown index reads as "no location" rather than clamping into range.
- `test/services/read_receipt_test.dart` (10) — parsing an `RCP:` read-receipt line. Its
  output goes straight into a SQL `IN` clause and its input is text off a Bluetooth socket
  from another device, so ids are checked for full uuid *shape*, not just length — one test
  uses a 36-character non-uuid that a length-only check would have admitted. Another pins
  that partial corruption keeps the valid ids rather than discarding the batch, since one bad
  entry would otherwise block those messages from ever being acknowledged.
- `test/utils/auth_error_messages_test.dart` (19) — what the user is told when auth fails.
  Pins that anything the user can *fix* never reports a server fault (the bug it was written
  for: a mistyped email threw a `TypeError` from the salt lookup and surfaced as "something
  went wrong on our end"), that a ban is never described as a suspension, and — in the other
  direction — that "wrong password" and "no such account" stay **identical**. The server
  collapses those too (0008/0009/0018/0023); splitting them client-side would turn the sign-in
  form into an account-existence oracle at the last step.
- `test/widgets/bar_chart_painter_test.dart` (20) — the hand-painted statistics chart.
  Painters do their own layout arithmetic (a reserved y-axis gutter, top headroom for the peak
  label, per-bar slot widths), and one that throws takes the whole admin screen down with a red
  error box. Pins the divisions and negative dimensions: empty series, all-zero, a peak of 1,
  30 buckets on a 280px phone, and a canvas narrower than the gutter. Also that `shouldRepaint`
  compares list *contents* — `fetch()` builds a fresh list every poll, so an identity check
  would repaint on every refresh regardless of whether anything moved.
  The x-axis labels added 5 Nov bring their own geometry: they reserve a 14px strip under
  the axis, so the baseline is no longer the canvas bottom and every height below it
  shifted. Covered for 30 daily and 24 hourly buckets, a single bucket, a canvas too short
  to hold the strip, and a label/value count mismatch — an index error inside `paint()`
  takes the whole admin screen down with a red error box.
- `test/widgets/password_strength_bar_test.dart` (10) — the password strength bar.
- `test/services/account_standing_test.dart` (18) — moderation verdicts: classifying the
  server's error into ban/suspension, and whether that verdict currently blocks the app.
  Pins that a non-moderation error (i.e. offline) is **never** read as a verdict, that both
  SQLSTATEs the server uses classify identically, that a lapsed suspension stops blocking
  with no server contact, and that an unparseable expiry fails *closed*. Every bug in this
  area is silent — see "Moderation enforcement" below.
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
- `test/views/flare_button_gesture_test.dart` (4) — behavioural, and the reproduction
  harness for a red screen reported on the Home flare button:
  `'_dependents.isEmpty': is not true`, which is
  `InheritedElement.debugDeactivated()` and therefore **debug-only** — it cannot fire in a
  release APK, so a red screen means a debug build. Pins that a tap never raises a flare
  (it only shows the hold hint), that a hold fires the callback exactly once (two would mean
  something is double-binding the gesture again, which is what `Tooltip`'s default
  `triggerMode: longPress` was doing), that an active flare's hold stands down rather than
  raising a second, and that tearing the screen down after several holds throws nothing.
  All four pass, which is what ruled the button widget out as the cause.
- `test/views/handshake_freshness_invariant_test.dart` (11) — another *source-level*
  guard. `FlutterBluePlus.scanResults` emits the whole accumulated list on every update and
  `removeIfGone` is **not** passed, so an entry never leaves it for the life of the scan —
  and because Android hands back a new random advertising address per re-advertise, a device
  reverting to its `HPS:` beacon usually arrives as a *different* entry, leaving the old
  handshake name in the list being re-delivered forever. For one-shot handshakes that is a
  live bug: a `WR:` sent days ago can be re-raised as a brand new watch request once the
  30-second dedup set expires. Name-based dedup cannot fix it (a genuine repeat is
  byte-identical), so `heardRecently` tests `ScanResult.timeStamp` against
  `_kHandshakeAdFreshness`. This test fails the build if any of `FR:`/`FA:`/`WR:`/`WA:`/`WX:`
  is dispatched without that check, if the window leaves the 15–120s range, if the `WR:`
  guard stops checking `_watchingBuddies`, if `_applyWatchCancelled` stops starting a
  cooldown, if `clearAllWatchState` clears only one half of the pair, or if the task-reminder
  dedup stops being persisted. Deliberately NOT applied to `EMG:`/`ADM:` — an emergency
  must never be dropped for being a few seconds stale.
- `test/views/contact_seed_exchange_test.dart` (3) — guards the *absence* of
  seed-over-manufacturer-data, having previously asserted its presence. That mechanism
  cannot work: manufacturer data and a local name do not fit in one 31-byte scan response,
  so the radio rejected the whole advertisement and took the handshake down with it. Strips
  comments before searching, because `hops_app.dart` deliberately names the removed helpers
  in prose so nobody re-adds them, and a naive search matches that prose. See "Naming a
  Radar dot" below.

- `test/database/import_export_test.dart` (16) — the restore half of Export My Data, and the
  first tests to touch `database_helper.dart` at all. Every path there reaches the file via
  `getApplicationDocumentsDirectory()`, a platform channel, which is why it had none;
  `openInMemoryForTest()` bypasses that one call so these run against the real `_onCreate`
  schema. Pins that import **merges** (an old backup onto a phone still in use loses nothing),
  is **idempotent** (same file twice adds nothing — every table has a real primary key and
  conflicts are ignored), and **never overwrites a local row** (the local copy may carry a read
  receipt the export predates). Also the two schema-drift cases: an export missing `read_at`
  (taken at v10) and one carrying a column this build has never heard of must both import
  rather than throw, which is why columns are intersected against `PRAGMA table_info` rather
  than a hardcoded list. One test feeds it `sqlite_master` to confirm a table name claimed by
  a user-supplied file is never handed to sqflite.

Still not covered: the rest of `database_helper.dart` beyond import/export. Nothing BLE, RFCOMM
or Nearby is covered — those need two physical devices, and no test suite will change that.

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
  request/accept), `WR:`/`WA:`/`WX:` (watch-buddy request/accept/cancel — `WX:` is sent by
  EITHER side, since the watched person must be able to withdraw too), `ACK:`/`HOP:` (manual pairing-code
  handshake), `CHT:` (chat ping — addressed to a peer by *truncated plaintext username*, not a
  rotating token, since you can't know a contact's token before a chat has ever connected),
  `VBT:`/`VBX:` (Vibe Check tag/expiry), `LNR:` (Lost & Found resolution),
  `SBF:`/`SBI:`/`SBC:`/`SBX:` (Study Bunny). A Study Bunny tag's **location** rides
  manufacturer data rather than the name (`kStudyLocationProtocolMarker`), because
  `SBF:<id>:` already costs 9 of the 26 bytes — and as a one-byte index into
  `kStudyLocations`, which is **append-only**: the index is the wire format.
  Chunked multi-part payloads have their own prefix constants in `hops_constants.dart`:
  `kCommunityChatPrefix` (`CM:`), `kAdminCommunityChatPrefix` (`CA:`), `kCommunityDeletePrefix`
  (`CX:`), `kDirectMessagePrefix` (`DM:`), `kLostFoundPrefix` (`LNF:`).
- Manufacturer data (`kCommunityManufacturerId`, `0xFFFF`) is a *second*, parallel channel riding
  the same advertisement — the Study Bunny location and the Discoverable name — and it only
  works on an advertisement whose *name* leaves room for it. **Use
  `manufacturerPayloadFitsWithName()`; the budget is `26 - nameBytes - 4`, which is far less
  than it looks.** `_advertiseWithName` now DROPS manufacturer data that will not fit and sends
  the name alone, because an over-full packet is rejected whole and would otherwise take the
  name down with it.
  **Flare/alert signature chunks (`encodeFlareSigChunk`) were listed here as a working user of
  this channel and never were.** Device-verified on a Galaxy A04e: `EMG:Victor:fire` is 15
  bytes, leaving 7 for payload, and a chunk wants 20 — the radio answered
  `ADVERTISE_FAILED_DATA_TOO_LARGE` and `_handleAdvertisingStatusUpdate` then cancelled the
  flare and told the user it had not gone out, a second after the plain name had advertised
  fine. **The signature was killing working flares.** It cannot be made to fit either: at 8
  chunks (chunkInfo packs 3 bits of index) a 256-byte RSA-2048 signature needs 32 bytes per
  chunk, more than the whole budget even with an empty name. `_startSignatureCycle` now checks
  and skips, leaving the alert on the air unsigned — an unsigned flare that arrives beats a
  verifiable one that never transmits. A name of ~22 characters already fills the
  scan response on its own, which is why seed chunks alongside a handshake name could never
  work (see "Naming a Radar dot"). There is
  only **one** manufacturer-data slot per advertisement, so these are mutually exclusive by
  construction — check `_advertisePresenceBeacon` before adding another user of it.
- Nearby BLE device count (app-bar chip) is a *separate*, unfiltered 3-second scan
  (`_updateBleDeviceCount`) so it reflects total ambient BLE traffic, not just Hops peers.

**Every advertisement name must fit `kAdvertisementNameMaxBytes` (26), measured in UTF-8
bytes.** Use `advertisementNameFits()` to check and `advertisementTextBudget(overhead)` to
size an input field — never a hand-written number. A feature that picks its own limit gets it
wrong: both Vibe Check (24) and Study Bunny (20) set theirs to the text budget with no
allowance for their own framing, so ordinary input overflowed the packet. The failure is
invisible from the sending side — `_advertiseWithName` now refuses an over-long name outright,
and `_handleAdvertisingStatusUpdate` surfaces radio failures for **every** feature rather than
only flares, which is what made this class of bug undiagnosable.

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

### 1c. Naming a Radar dot, and why only chat can teach a seed

The idle beacon broadcasts `HPS:<rotating token>`, not a username —
deliberate anti-tracking, but it means Radar **cannot** name a dot by
string comparison. `RadarScreen._resolveToken` names one by trying each
contact's stored *rotating seed* against the observed token. That only
works if the seed is on file locally, and **exactly one route puts it
there**: the RFCOMM profile exchange on first 1:1 chat
(`chat_terminal.dart` → `upsertContactRotatingSeed`).

So a contact you have added but never chatted with shows as an anonymous
dot. That is a real limitation, not a bug to go and fix casually — read
the rest of this section before trying.

**Do not teach the seed over manufacturer data.** It was attempted twice
and cannot work. Manufacturer data and a local name cannot share one
31-byte BLE scan response:

```
name "WR:<user>:<user>"    24 bytes  (2 AD header + 22 chars)
manufacturer seed chunk    24 bytes  (4 AD header + 20 payload)
                           ──
                           48 bytes  → ADVERTISE_FAILED_DATA_TOO_LARGE
```

The radio rejects the **whole advertisement**, so the handshake itself
never leaves the device either — the seed exchange does not merely fail,
it takes the watch request or friend request down with it.

This sat unnoticed in the watch handshake (`WR:`/`WA:`) for a long time
because the verdict arrives on an async callback that only reported
*flare* failures. Extending the same pattern to the friend handshake is
what exposed it: friend requests started visibly failing with "data too
large" on real hardware. Both are now removed, and
`test/views/contact_seed_exchange_test.dart` fails the build if either
helper reappears or if any of the four handshake senders attaches
manufacturer data.

**If it is worth doing properly**, the viable channel is a dedicated
chunked *name* payload with its own prefix, the way `CM:`/`DM:` already
work — 24 bytes of seed is two base64 chunks. That needs a sender tag in
each chunk so the receiver knows whose seed it is, which is the part that
makes it real work rather than a two-line addition. Do the byte arithmetic
first, every time.

Note the wire constants are still named `kWatchSeed*` /
`kWatchSeedProtocolMarker` (`0x53`) and `encodeWatchSeedChunk` /
`decodeWatchSeedChunk` still exist in `hops_constants.dart`. They are
currently unused by any sender. Left in place rather than deleted because
the marker byte must not be reassigned to something else while any
installed build might still parse it.

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
  `onProfileReceived`) that syncs a contact's avatar and bio.
- **Read receipts** ride the same line protocol as `RCP:<uuid>,<uuid>,…` — one line for a whole
  backlog rather than one per message. `messages.read_at` (schema v11) holds the three states:
  `delivered = 0` is pending, `delivered = 1` with a null `read_at` is sent, and a non-null
  `read_at` is read. That column means **two different things depending on direction** — on an
  outgoing row it is when the peer reported reading it; on an inbound row it is our own marker
  that we have already acknowledged it and need not again. Receipts are sent only while the
  thread is *open*, not when a message arrives, because a receipt should mean a person saw it.
  They are deliberately not queued: a receipt is worth nothing except live, and the backlog is
  re-acknowledged on the next connect anyway. That exchange is the **only** way
  cosmetics cross devices — see `services/cosmetic_prefs.dart`'s header.
- **The first connection to a given contact needs Wi-Fi switched on at both ends.** Android
  leans on it during classic-BT discovery, and without it the two phones routinely never find
  each other. It only bites *once*: after one successful connection each side has the other's
  MAC (`contact_profiles.rfcomm_mac`, written by `onMacLearned`) and connects straight to it,
  skipping discovery. `chat_terminal.dart` shows a hint above the thread while
  `_firstEverConnection` (i.e. no MAC on file) and not yet connected, and it self-dismisses the
  moment a connection lands. The wording states that the radio only needs to be **on**, not
  joined to a network, and that no data is used — otherwise it reads as a contradiction of the
  app's whole offline claim, which is the kind of doubt that's much more expensive than the
  hint itself. The mechanism (Android gates discovery results behind Location, and Android's
  location service leans on Wi-Fi scanning; a failing gate returns an empty result, never an
  error) is written up in `docs/report-rfcomm-wifi-dependency.md`, along with the BLE
  MAC-exchange change that would remove the dependency altogether.
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

`profiles.role`, the moderation tables, the admin action log and **Community Alerts** are the
only other server-side state — all other feature data (chat, tasks, vibes, study tags, games)
never leaves the device.

**Community Alerts is the one peer-facing feature with a server path, and that is deliberate.**
It is not a peer feature: admin-to-everyone, read-only for students, and it already depended on
server state to be trusted at all — the receiver drops any `CA:` chunk whose sender tag does not
resolve through `KeyDirectory` to a cached account with `role = 'admin'`, and KeyDirectory syncs
over the internet. So a student who had never been online silently discarded every alert with
Bluetooth working perfectly. `0024` + `services/community_alert_sync.dart` add an explicit
server path in place of that implicit, fragile one, and get durability for free:

| Bluetooth | Internet | Delivered by |
|---|---|---|
| on | off | BLE, immediately |
| off | on | the server, on the next 30s poll |
| off | off | whichever comes back first |

BLE remains primary — an alert still reaches everyone in range with no internet at all. The
server is the **catch-up** path. Dedup is on `(senderTag, msgId)`, the same pair the BLE
receiver keys reassembly on, so an alert arriving by both routes lands once. The fetch lives on
`hops_app.dart`'s poll, **not** in the Community Alerts page: that page only exists once its tab
has been built, which is the same mistake that stopped Vibe Check and Study Bunny being heard
unless their page was open.

**This bounds what the admin statistics can ever say.** `0022_admin_statistics.sql` plus
`services/admin_stats_service.dart` back a filterable, charted view (24h/7d/30d/custom range,
hand-painted `CustomPainter` charts with y-axis and per-bar values — no chart dependency,
so they inherit the active theme),
a most-active-users ranking, and CSV export. But the server holds no message, chat or feature
data, so none of it can be reported on and nothing there pretends to; the screen says so
explicitly, because a dashboard that silently omits all feature usage invites the conclusion
that nobody uses the app. One trap worth knowing: **`admin_actions_log` is not purely admin
activity** — `log_emergency_flare` writes a row with the *raising student* as
`actor_username`, so anything counting "admin actions" must exclude
`action = 'emergency_flare'` or it double-counts student activity as moderation.

**`public.profiles` is not created by any migration.** It was made in the Supabase dashboard, so
which constraints it carries was never under version control — and that is how two accounts came
to share a username. `signup_hops_user` never had an explicit duplicate check; it relied entirely
on catching `unique_violation` from the INSERT, and with no unique index in the database no
violation was ever raised and the duplicate was created silently. `0020` adds
`profiles_username_unique_ci` on `lower(username)` plus an explicit pre-check, and refuses to run
with a clear listing if duplicates already exist (resolving them is a judgement call, so no
migration here deletes an account). Case-insensitive deliberately: the wire format truncates
sender tags to 8–9 characters, so `Victor` and `victor` are indistinguishable to most of the
protocol. `0020` also restores the reserved-bot-username check that `0014` added and `0018`
dropped when it re-created the function for the password salt.

### 4c. Moderation enforcement (ban & suspend)

Every bug in this area is **silent**: the symptom is "the admin action did nothing", which is
indistinguishable from the admin app being broken. It was broken in four places at once, found
during testing on 21 Oct 2026. Fixed in `0020_username_uniqueness_and_standing_enforcement.sql`
and `services/account_standing.dart`.

What the two verdicts mean, and why they behave differently:

- **Ban** — permanent, no expiry. `ban_user` also sets `token_expires_at = now()`, killing the
  session server-side.
- **Suspend** — expires by itself. `suspend_user` deliberately does **not** touch
  `token_expires_at`: a dead token would leave the account looking permanently signed out long
  after the suspension lapsed. That is exactly why the sign-in path has to carry the check.

The four gaps that made it look like nothing happened:

1. **Neither sign-in function checked suspension.** `suspended_until` arrived in 0015, which
   taught `get_my_status` about it and nothing else. `signin_hops_user` was last defined in 0008
   and `signin_hops_user_by_email` in 0009 — both predate the column. A suspended user signed
   out and back in and was let straight through. Ban had this same hole closed in 0008.
2. **No enforcement at launch.** `main.dart` routed into `HopsApp` purely on
   `saved_hops_token != null`. Force-close and reopen put a moderated user back in until a poll
   next happened to succeed. The launch path now reads the persisted verdict first.
3. **The verdict was never written down.** It lived in a local variable, so restarting the app
   discarded it — and because Hops is offline-first, "a poll that succeeds" can be days away.
   `AccountStandingStore` persists it to `SharedPreferences`.
4. **`describeAuthException` had no `account_suspended` branch**, so a suspended user's sign-in
   fell through to the generic "something went wrong on our end" — a working suspension reading
   as a server fault. It also described a *ban* as "suspended", which invites someone to wait
   out something permanent instead of appealing. The admin app's own poll had the same two
   defects independently.

Invariants worth preserving:

- **A failed check is not a clean bill of health.** `AccountStandingStore.refresh` returns
  `null` when it could not ask (offline, Supabase unreachable) and the stored verdict stands.
  Never collapse `null` into "in good standing" — in an offline-first app that is the same as
  having no moderation.
- **Classify on message *and* details, not just `message`.** The two server paths raise with
  different SQLSTATEs for the same condition (28000 from sign-in, 42501 from `get_my_status`),
  so nothing may depend on the code. And `details` is typed `dynamic` — a blind `as String`
  throws a `TypeError` from inside the handler whose job is to stop the app ignoring a ban.
- **A lapsed suspension lifts itself with no network.** The expiry is known locally, so a
  device that is offline when the week ends must not stay locked out — that is a punishment
  nobody imposed. A ban has no expiry and cannot self-lift; an unban is only discoverable by
  asking. That asymmetry is correct, don't "fix" it.
- **An unparseable suspension expiry fails closed** (blocks). A re-check can always lift it;
  guessing "not blocked" silently discards the moderator's decision.
- **Both verdicts end the session immediately and land on the gatekeeper.**
  `endSessionForModeration` removes `saved_hops_token`, so there is nothing for the launch path
  to re-enter `HopsApp` with and nothing to navigate back to. An earlier attempt held the
  session and covered the app with a barrier screen; that left a live token in place, which is
  not what "their session is terminated" means. Don't reintroduce it.
- **Neither verdict deletes local data.** Messages, contacts, tasks and vibe records all
  survive a ban as well as a suspension; only the session token goes. A ban used to trigger the
  full wipe on the reasoning that it is permanent — which is wrong on its own terms, because
  `unban_user` exists. An unbanned student would have returned to an empty app with every
  conversation gone, and a student banned by mistake had no recourse at all. Destroying data
  irreversibly as a side effect of a reversible decision is not a trade any moderator made or
  was offered, and the data is the user's own, on the user's own device: moderation removes
  their access to the network, which the server-side block already does. Only three things
  wipe — Log Out, Delete Account (both explicit, behind a confirmation naming what is lost) and
  `discardLocalDataForAccountSwitch`. `my_hops_id` is left behind precisely so that last
  comparison can be made.
- **That marker is load-bearing.** Keeping a database across a sign-out is the *only* state in
  which the next person to sign in on that phone could inherit someone else's threads — sign-in
  does no account-switch check of its own, it just overwrites prefs. So
  `discardLocalDataForAccountSwitch` runs on every sign-in and wipes when the authenticated id
  differs from the stored one. It must stay **before** the prefs writes that overwrite
  `my_hops_id`, or it compares against the value it was meant to detect a change from.
- **The gatekeeper says why.** A moderation sign-out is otherwise indistinguishable from being
  logged out at random. `_explainModerationSignOutIfAny` reads the persisted verdict (no
  network) into the existing status banner.
- **The local sign-in pre-check is scoped to the blocked account's own email.** It refuses a
  sign-in the server would refuse anyway, which matters because it works offline — but
  blocking *every* sign-in on the device because the last user was suspended would lock out
  everyone else sharing the phone.
- **The admin app needs all of this too, and didn't have it.** `admin_shell.dart`'s poll
  checked only `account_banned`, so a *suspended* admin kept the admin app and every
  moderation power in it — including acting on whoever suspended them. `main_admin.dart` also
  had no launch gate, so force-closing restored those powers. Both fixed; `main_admin.dart`
  preloads the verdict before the first frame so the gate reads a populated value.

Still true and not fixable here: a device that **never** goes online cannot learn it has been
moderated. Nothing in the local BLE data plane consults the server, by design. The launch gate
and the persisted verdict narrow the window to "one successful poll, ever", which is the best
this architecture allows.

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
  (`_databaseVersion`, currently 11) with four tables: `messages` (mesh chat log + relay queue),
  `vibe_records`, `tasks`, `contact_profiles` (peer avatar path / bio, populated by the RFCOMM
  profile exchange). On Windows/Linux, `main.dart` swaps in `sqflite_common_ffi`. Bump
  `_databaseVersion` and add an `_onUpgrade` branch for schema changes — don't edit `_onCreate`
  alone once the app has shipped.
**Export has an import.** `exportAllData`/`importAllData` are the two halves of Account
Management's backup. Import **merges** and never overwrites — an old backup restored onto a
phone still in use loses nothing, and the same file twice is a no-op because every table has a
real primary key and conflicts are *ignored* rather than replaced (a local row may carry a read
receipt or delivered flag the export predates). Columns are intersected against the live
`PRAGMA table_info`, so an export from an older or newer schema imports rather than throwing.
`localDataRevision` is what tells the still-mounted `HopsApp` to re-query its contacts tray
afterwards — without it a restore appears to do nothing until something unrelated refreshes.

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

- **`askBunny(query)`** — keyword lookup over `assets/data/hops_knowledge.json` (74
  entries). An entry carries either `response` (one answer) or `responses` (a list, picked
  from at random) — jokes need the latter, since a single fixed string meant "tell me
  another" returned the same joke forever. An entry with neither, or with no keywords, is
  dropped by the loader, so `knowledgeEntryCount` is the figure to trust rather than the
  file's length. **No keyword may be claimed by two entries**: scoring is
  `words*10 + length` per keyword and the highest total wins, so a shared keyword makes the
  answer depend on whatever else happened to be in the sentence.
  `test/services/hops_knowledge_test.dart` (27) runs against the REAL shipped asset and
  fails on a malformed entry, a shared keyword, a loader-dropped entry, or a plausible
  question routing to the wrong topic. This is what backs the built-in contact named `Hops`
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
catalog feature; it's reached from a persistent button on the **Features** tab
(`_buildShopButton`). It had one on Radar/Home too until 5 Nov 2026, when the Emergency
Flare took that slot back — see "Emergency Flare" below.

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
  alert registry.
  `services/foreground_service.dart` WAS dead code (nothing imported it, so its `MyTaskHandler`
  was never registered and the service ran no Dart at all) and is **deleted**, replaced by
  `services/background_flare_task.dart` — see "Hearing a flare with the app closed" below.
  `views/half_wheel.dart` is still dead; delete it or wire it up, don't assume it runs.
- Theming is data-driven: `theme/app_theme.dart` defines an `AppTheme` model and `AppThemes.all`
  catalog; the active theme index lives in a global `themeNotifier` (`main.dart`) persisted to
  `SharedPreferences`. Both entry points read it.

### 8. Emergency Flare — triggers and known limits

Three triggers, and **all** of them open the same confirm-then-reason dialog — none
skips confirmation:

- The Quick Settings tile (`HopsSosTileService.kt`), delivered cold-start via `consumePendingSos`
  or warm via `onNewIntent`.
- The app-icon shortcut (`quick_actions`, `shortcutNotifier`).
- **The app-bar button on the Radar/Home tab** (`radar_screen.dart`'s `_buildFlareButton`),
  added 5 Nov 2026 in the slot the Hops Shop had taken. It is **long-press**, restoring the
  gesture the original button used. A flare button had been removed from exactly this spot once,
  for two stated reasons, and both are answered rather than ignored: "easy to set off by
  accident" is handled by requiring a deliberate hold, then a confirmation, then a typed reason
  — a tap cannot raise a flare and instead says which gesture is needed, because a control
  that ignores taps silently reads as broken. (A correction worth keeping: the removed button was
  described here as "hold-to-fire". Checking `29e5265` shows it was `onLongPress` opening the same
  confirm dialog, so that was never accurate.) And
  "useless in the situation it exists for" argues it is not *sufficient*, not that it is
  harmful — the tile and shortcut remain for the phone-in-pocket case, and this is additive
  for when the app is already open. While a flare is active the same button becomes the
  **stand-down**, because the active-flare SnackBar's CANCEL can be swiped away or time out
  and then there is no way back to it. Its red is hardcoded, deliberately — every theme can
  recolour `primary`, and a danger control that renders mint green under one theme stops
  reading as danger at a glance. The Shop is **not** orphaned: it keeps its labelled pill on
  the Features tab (`_buildShopButton`).

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

**A flare stays live for five minutes** (`kEmergencyFlareDuration`). It was 30s, then 60s;
a minute is about how long it takes to notice an alarm and work out which direction it came
from, which left no time to actually reach the person. Everything derives from that one
constant — the sender's auto-cancel timer and countdown SnackBar, `NotificationService`'s
`_alertAutoExpiry`, and `background_flare_task.dart`'s `_kAlertExpiry` (both
`+ 30s`). **Don't hardcode a second copy**: the background task's expiry *was* a literal
3 minutes, which the moment this went to 5 would have let it drop an alert while the sender
was still broadcasting. The flare advertises once and stays on air for the whole window —
there is no re-advertise cycle — so this is five minutes of continuous transmit. An admin's
Official Alert (`ADM:`) keeps its own separate 30-second window in
`official_alert_service.dart` and is deliberately untouched by this. Use
`describeAlertDuration()` for any user-facing wording; the SnackBar interpolated `.inSeconds`
and read "300 seconds".

### 8b. Hearing a flare with the app closed

`services/background_flare_task.dart` is the only thing in this app that runs with no UI. Read
this before touching it.

**Why it exists.** Every BLE scan lives in `_HopsAppState`, a widget. Swiping the app away
destroys the Activity, the engine and the only listener, so the foreground notification went on
claiming "Scanning for emergency flares" while nothing was. `flutter_foreground_task` can run a
handler in a separate isolate that survives that, but `startService` was being called with **no
`callback:`** — so no handler was ever registered.

**It runs ALONGSIDE the UI isolate, not instead of it.** The task isolate starts with the
service, i.e. at app launch. Two scans from one app fight over the radio and two listeners mean
two alarms for one flare, so the handler only takes over once the UI has gone quiet:
`HopsRoot` stamps `ui_isolate_heartbeat_ms` every 5s and the handler listens only when that is
more than 20s stale. A **heartbeat, not a lifecycle callback** — a swipe-away or a low-memory
kill gives no reliable callback, and a flag set on `paused` would wrongly fire for a
backgrounded-but-alive app that is still scanning fine. The reader MUST call `prefs.reload()`:
each isolate caches SharedPreferences, so without it the handler reads the value from when it
started, forever.

**It cannot use `NotificationService`.** That class's state (the alert registry,
`isAlarmRinging`, the `AudioPlayer`) lives in the UI isolate. The handler has its own channel,
`emergency_flare_background`, with `playSound: true` and alarm `audioAttributesUsage` — the
in-app channel sets `playSound: false` because the app drives audio itself, which is not
dependable headless. **The trade: the OS plays the tone ONCE rather than looping it.** A single
loud alarm plus a full-screen intent is what is reliably achievable with no UI isolate.

**Three things it must keep doing that are each a bug it already had.** It filters our
**own** flares (`isOwnAlert`, exact sender match, tag truncated to 8) — the UI isolate always
did and this did not, so raising a flare and backgrounding for 20s alarmed the sender's own
phone, unstoppably, since reopening the app to cancel stops this handler scanning before the
`EMG_OFF:` arrives. It keeps `_raisedRecently` **across** a stand-down for
`kEmergencyFlareDuration + 5s`, because `scanResults` still holds the flare's own entry inside
the freshness window and re-raised it a millisecond after cancelling. And on handing the radio
back to the UI it **cancels its own notifications** (`_clearOwnAlerts`), which it can no longer
stand down once it stops scanning.

**Scope is deliberately tiny**: raise and stand down, nothing else. No relaying, no signature
check, no Watch Me, no chat. Everything else can wait for the app to be opened; an alarm cannot.

It applies the same freshness rule as the UI dispatch (`scanResults` never drops entries, so a
flare heard once would otherwise re-raise forever) and the same trailing-colon stand-down
scoping. `flareKeysStoodDownBy` is pulled out as a pure function precisely so that rule is
testable — `test/services/background_flare_task_test.dart` (8).

**NOT device-verified.** It compiles and the pure logic is covered, but whether
`flutter_blue_plus` actually scans from this isolate on a given handset, and whether Samsung's
battery management lets the service live after a swipe-away, can only be answered on hardware.
Set the app to **Battery — Unrestricted** and exclude it from "Put unused apps to sleep" before
concluding anything.

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
powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1 -Keep # same, but leave the restored db to browse
powershell -ExecutionPolicy Bypass -File .\scripts\reset-local-pg-password.ps1   # ELEVATED; forgot the local postgres password
```

`-ExecutionPolicy Bypass` is required — the machine default is Restricted. It scopes to that one
invocation.

Last verified restore: **4 Nov 2026**, 9 tables and 140 rows into a local scratch database (was 8 tables / 67 rows on 1 Sep 2026).
The scratch database (`hops_restore_test`) is dropped in a `finally` block, so nothing survives the run unless `-Keep` is passed — worth knowing before hunting for it afterwards. A kept database holds every row of the cloud database, password hashes and the full moderation log included, so delete it (`dropdb hops_restore_test`) once you are done looking.

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

Current shape of the backend, useful for sanity-checking a dump: 9 tables, all with RLS enabled
and **zero policies** (deny-all by design — everything goes through 65 `SECURITY DEFINER`
functions), 74 `REVOKE`s, 61 `GRANT EXECUTE`s. If a dump comes back with policies in it, something
changed. The ninth table is `community_alerts`, added by `0024` — so a restore reporting only 8 is itself evidence that `0024` never applied, which is a cheaper check than reading the function list. The `SECURITY DEFINER` count also moves with each migration (`0024` adds three functions, `0025` one), so treat 65 as the figure at `0023` rather than a constant.

`0026_retire_plaintext_email.sql` is written but **deliberately unapplied** — it drops
`profiles.email` and rewrites the eight functions that read or write it. It is irreversible and
gated on both Vault keys being stored off the database; its header carries the prerequisites and
a rehearse-on-a-restored-copy procedure. Worth knowing if you touch anything on the email path:
`0021`'s own section-8 list of readers to rewrite is **wrong in both directions** — it missed
`get_password_salt_by_email` (which every email sign-in calls first, so following that list
breaks sign-in for everyone) and named `admin_list_users`, which does not exist in this schema.
`0026`'s header has the real list and how it was derived.

Since `0020` there is also a unique index `profiles_username_unique_ci` on
`lower(username)` — a dump without it means `0020` was never applied, and duplicate usernames are
possible again.

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
