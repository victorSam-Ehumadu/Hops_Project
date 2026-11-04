# 5.2 Coding — Languages, Tools and Their Feasibility

## 5.2.1 Overview

Hops is built in **six languages**, each confined to the layer where it is the only
sensible choice. None was selected for familiarity or preference; in every case the
language was determined by a hard constraint of the platform the code has to run on.

| Language | Where it runs | Files | Lines | Share |
|---|---|---:|---:|---:|
| **Dart** | The Flutter application (student + admin) | 100 | 35,380 | 80.8% |
| **SQL (PL/pgSQL)** | PostgreSQL migrations and stored procedures | 19 | 3,785 | 8.6% |
| **HTML / CSS** | Marketing and download website | 6 | 1,445 | 3.3% |
| **Dart (tests)** | Automated test suite | 7 | 1,347 | 3.1% |
| **Kotlin** | Android native layer | 4 | 716 | 1.6% |
| **TypeScript** | Supabase Edge Functions (email delivery) | 7 | 602 | 1.4% |
| **PowerShell** | Database backup and recovery scripts | 3 | 486 | 1.1% |
| **Total** | | **146** | **43,761** | 100% |

Measured by line count across the repository. Dart dominates because the application
itself is the system; everything else exists to support it.

---

## 5.2.2 Dart — the application language

**Version:** Dart 3.x (`sdk: '>=3.0.0 <4.0.0'`), Flutter 3.41.6 stable.
**Scope:** the entire user interface, all business logic, the Bluetooth protocol
encoding/decoding, local persistence, cryptography and both entry points.

### Why Dart is feasible for this project

**It is not a free choice — it follows from choosing Flutter.** Flutter is written in
Dart and compiles Dart; selecting the framework selects the language. So the
justification is properly a justification of Flutter, and it rests on three project
constraints:

1. **One codebase, two applications.** Hops ships a student app and an administrator
   app. They share identity, cryptography and Bluetooth code but differ in interface
   and privilege. Flutter supports multiple *entry points* into one package
   (`lib/main.dart` and `lib/main_admin.dart`), so both are built from the same source
   tree and the same APK, and shared code physically cannot diverge between them.
   Writing them as two native applications would have doubled the work and guaranteed
   drift.

2. **The project must be demonstrable on whatever hardware is available.** Flutter
   compiles the same source to Android and to Windows desktop. The Windows build is
   what makes the system presentable without a physical handset, which matters for an
   assessed demonstration.

3. **Ahead-of-time compilation to native ARM.** Dart compiles to machine code for
   release builds rather than running interpreted. This matters here specifically:
   the application runs a continuous Bluetooth scan in a foreground service, parses
   every advertisement it hears, and must stay responsive while doing so on
   low-specification handsets. An interpreted or bridged runtime would spend battery
   and latency the system cannot afford.

**Null safety** is a further practical argument. The Bluetooth layer deals almost
entirely in values that may be absent — a peer that never responds, a key not yet
exchanged, a truncated payload. Dart's type system forces every one of those to be
handled at compile time rather than discovered as a null-reference crash on a user's
phone during an emergency alert.

### Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Kotlin (native Android)** | Best possible Bluetooth access, but Android only, and the admin app would have had to be a separate project or an awkward build flavour. The parts that genuinely need native access are written in Kotlin anyway (below), so nothing is lost. |
| **React Native** | JavaScript bridge overhead on a continuous scan loop, and weaker Bluetooth peripheral support. Desktop support is not first-party. |
| **Java (native Android)** | Same platform limits as Kotlin, with more verbosity and no null safety. |

---

## 5.2.3 Kotlin — the Android native layer

**Scope:** 683 lines across four files — `MainActivity.kt`, `RfcommChatService.kt`,
`HopsSosTileService.kt`, `FoundDeviceReceiver.kt`.

### Why Kotlin is necessary rather than merely convenient

Three capabilities the system depends on have **no Flutter plugin that exposes them**,
so they are written directly against the Android SDK and bridged to Dart over platform
channels:

1. **RFCOMM sockets over classic Bluetooth.** One-to-one chat needs a real, persistent,
   bidirectional socket, which BLE advertisements cannot provide. `RfcommChatService.kt`
   opens `BluetoothSocket` connections directly. It also implements a connection
   watchdog, because `BluetoothSocket.connect()` has no timeout and can block
   indefinitely on some Bluetooth stacks — a problem only reachable from native code,
   since the fix is to *close the socket* from another thread rather than cancel the
   call.

2. **The Quick Settings tile.** `HopsSosTileService.kt` extends Android's
   `TileService`, which has no Flutter equivalent. It is what allows the Emergency
   Flare to be triggered from the notification shade without unlocking the phone.

3. **Classic-Bluetooth device discovery.** `FoundDeviceReceiver.kt` is a
   `BroadcastReceiver` for `ACTION_FOUND`, streamed to Dart over an `EventChannel`.

Kotlin rather than Java because it is Google's recommended language for Android, it has
null safety comparable to Dart's, and coroutines express the socket-with-timeout pattern
far more clearly than threads and callbacks would.

**Kotlin is deliberately kept minimal — 1.6% of the codebase.** Every line of it is
platform-specific and cannot be tested without a physical device, so the boundary is
drawn to keep as much logic as possible on the Dart side, where it is testable.

---

## 5.2.4 SQL / PL/pgSQL — the database layer

**Scope:** 3,785 lines across 19 numbered migration files, defining 8 tables and 65
`SECURITY DEFINER` stored procedures.

### Why the database logic is written in SQL rather than in the application

This is the most consequential language decision in the project, and it is a **security**
decision, not a convenience one.

The application ships with an anonymous API key embedded in it, which must therefore be
assumed public. If authentication logic lived in Dart, it would run on a device the
attacker controls, against a database the attacker can query directly with that key.

Writing it as PL/pgSQL stored procedures moves the logic to the one place the attacker
cannot reach. `signin_hops_user` executes inside PostgreSQL, compares the password hash
server-side, and returns only a safe subset of columns. The hash goes in and never comes
back out. Every table has Row Level Security enabled with **zero policies** — a deny-all
posture — so the procedures are the entire permitted surface. This is documented fully
in §4.8.

A second benefit follows automatically: **SQL injection is eliminated as a category
rather than mitigated.** No user input is ever concatenated into a query. Every call is
an RPC with named, typed parameters, which PostgreSQL binds as data and can never
interpret as code.

PL/pgSQL specifically (rather than plain SQL) because the procedures need control flow —
attempt counters on one-time passcodes, expiry checks, conditional branches on
moderation state.

---

## 5.2.5 TypeScript — Supabase Edge Functions

**Scope:** 602 lines across 7 files, handling outbound email only — verification codes,
password-reset codes, moderation notices.

Supabase Edge Functions run on **Deno**, which executes TypeScript natively. The language
is therefore given by the platform, exactly as Dart is given by Flutter.

These exist for one reason: sending email requires an API credential that must never be
placed in a client application, where it would ship to every user. The Edge Function
holds the credential server-side and the application simply requests that a message be
sent. TypeScript's static typing also makes the contract between the Dart caller and the
function explicit at both ends.

---

## 5.2.6 HTML and CSS — the project website

**Scope:** 907 lines across 5 files. Static marketing and download pages, no build step,
no framework, no JavaScript dependencies.

Feasible precisely *because* it is minimal. The site's job is to describe the project and
host the APK download. A framework would add a build pipeline, a dependency tree and a
deployment step to a set of pages that do not change. Plain HTML and CSS can be hosted
anywhere at no cost and will still work unchanged years from now.

---

## 5.2.7 PowerShell — operational scripts

**Scope:** 486 lines across 3 scripts — `backup-db.ps1`, `verify-backup.ps1`,
`reset-local-pg-password.ps1`.

PowerShell is the native shell of the development platform (Windows), so it needs no
runtime installed and can call `pg_dump`, query Windows services and read the registry
directly. A Bash equivalent would require WSL or Git Bash to be present.

It also provides the specific facility these scripts depend on: `Read-Host` accepts the
database connection URI without recording it to shell history, which is what keeps the
database password out of `ConsoleHost_history.txt`. See §4.8.4.

---

## 5.2.8 Supporting libraries

31 third-party packages, all from `pub.dev`, the official Dart package registry. The ones
that carry real architectural weight:

| Package | Purpose | Why this one |
|---|---|---|
| `flutter_blue_plus` | BLE scanning (central role) | Actively maintained; supports the hardware service-UUID scan filter the radar depends on |
| `ble_peripheral` | BLE advertising (peripheral role) | One of very few packages exposing the peripheral role at all, which the entire wire protocol requires |
| `nearby_connections` | Hops Share file transfer | Wraps Google's Nearby Connections; streams files from disk rather than loading them into memory |
| `sqflite` | On-device database | The standard SQLite binding; `sqflite_common_ffi` gives the same API on Windows |
| `flutter_secure_storage` | RSA private key | Backed by the Android Keystore — hardware-backed where available |
| `crypton` | RSA keypair, signing | Signs Emergency Flares so a recipient can verify the sender while completely offline |
| `supabase_flutter` | Backend RPC calls | Official client for the chosen backend |
| `flutter_foreground_task` | Background scanning | Keeps BLE scanning alive when the app is not in the foreground, which is what makes emergency alerts work at all |
| `flutter_dotenv` | Credential loading | Keeps Supabase credentials out of source control |

### Development and verification tooling

| Tool | Use |
|---|---|
| `flutter analyze` | Static analysis against `flutter_lints`; the primary gate for radio-related changes, which cannot be unit-tested |
| `flutter_test` | 125 automated tests covering the wire format, credential rules, currency, the Bluetooth name guard, the emergency-flare radio invariant, and the accessibility toggles |
| Git / GitHub | Version control, branch-per-feature |
| Android Studio | Android toolchain, emulator, device deployment |
| PostgreSQL 17 client tools | `pg_dump` for backup, `psql` for verified restore (§4.8.5) |
| Supabase CLI / dashboard | Migration application and database administration |

---

## 5.2.9 Summary of feasibility

Every language in this system is present because a specific constraint required it, and
each is confined to the layer where that constraint applies:

- **Dart** is the application language because Flutter was selected, and Flutter was
  selected because the project needs two applications from one codebase, on two
  platforms, compiled to native code.
- **Kotlin** covers exactly the three capabilities Flutter cannot reach — RFCOMM
  sockets, the Quick Settings tile, and classic-Bluetooth discovery — and nothing else.
- **SQL/PL/pgSQL** holds all authentication and moderation logic because that is the only
  location an attacker holding the public API key cannot reach.
- **TypeScript** is imposed by Deno, and exists solely to keep the email credential off
  user devices.
- **HTML/CSS** is deliberately unframeworked because the site is static.
- **PowerShell** is the platform-native shell and offers the history-free input the
  backup procedure requires.

The strongest evidence of feasibility is that the system is complete and running: a
working application on both Android and Windows, a live backend with a tested backup
and recovery procedure, and an automated test suite that passes.
