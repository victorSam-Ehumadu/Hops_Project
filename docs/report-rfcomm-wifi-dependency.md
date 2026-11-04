# Why the first 1:1 chat connection needs Wi-Fi switched on

Source of record for the explanation. The in-app hint
(`chat_terminal.dart`) and CLAUDE.md's RFCOMM section both summarise this;
edit here and keep those in step.

## The claim, stated precisely

RFCOMM chat does not use Wi-Fi, and Hops transfers no data over it. What
needs the Wi-Fi radio switched on is the **first** connection to a given
contact, and only because of how Android gates Bluetooth **device
discovery**. The radio needs to be *on*; it does **not** need to be joined
to a network.

This matters to state carefully, because "turn on Wi-Fi" sounds like a
contradiction of the project's central claim that Hops works with no
internet. It is not one — but a listener who is not given the distinction
will reasonably assume it is.

## Why only the first time

A classic Bluetooth connection needs the peer's **MAC address**. Given
one, connecting is:

```
BluetoothDevice.createInsecureRfcommSocketToServiceRecord(uuid).connect()
```

which is pure Bluetooth — no IP address, no DNS, no Wi-Fi, no internet.

The first time two devices chat there is no MAC on file, so the app has to
go and *find* the peer: `BluetoothAdapter.startDiscovery()`, a classic
Bluetooth inquiry, with results arriving as `ACTION_FOUND` broadcasts
(`FoundDeviceReceiver` in `MainActivity.kt`). Discovery is the part Wi-Fi
affects.

After one successful connection each side stores the other's address
(`contact_profiles.rfcomm_mac`, written by `onMacLearned`) and every later
connection goes straight to it, skipping discovery entirely. That is why
the dependency appears exactly once per contact and then never again — and
why the in-app hint is gated on there being no MAC on file.

## The mechanism: Android ties Bluetooth discovery to Location

This is the dominant reason and the one to lead with, because it is in
Android's documented behaviour rather than in any one vendor's firmware.

Android treats "what Bluetooth devices are near me" as physical-location
information, because it is: a list of nearby radios identifies a place.
So, since Android 6, **Bluetooth scan and discovery results are gated
behind location access** — not just the permission being granted, but
Location Services being switched on at the system level. That is why
`services/bluetooth_permissions.dart` requests location on every Android
version, not only the Bluetooth permissions.

The consequence that produces this bug: when the location requirement is
not met, Android does **not** return an error. `startDiscovery()` succeeds,
the discovery-started broadcast fires, the scan appears to run, and simply
no devices are ever found. An empty result is indistinguishable from
"nobody is nearby".

Wi-Fi enters because of how Android *resolves* location. The platform's
fused location provider uses Wi-Fi scanning as a primary input — it is what
makes location work indoors, where GNSS does not. With the Wi-Fi radio off,
the location subsystem on many builds degrades or reports itself
unavailable, and Bluetooth discovery then yields its silent empty result.
Switching Wi-Fi on restores the location input, and discovery starts
returning devices again.

Note what this does **not** require: the Wi-Fi radio performs *scanning*
while unassociated. It never joins a network, no DHCP lease is taken, and
no bytes are sent or received by Hops. "On" is doing real work here; "connected"
is not needed.

## A contributing factor: one antenna, two radios

Worth knowing as a secondary effect, and worth being careful not to
overstate.

Essentially every phone uses a **combo chip** in which Wi-Fi and Bluetooth
share a single 2.4 GHz front end and antenna. The firmware arbitrates
between them. On some vendor stacks the Bluetooth side's coexistence state
is brought up as part of the shared WLAN/BT subsystem, so with Wi-Fi hard
off the chip can sit in a reduced-power configuration that shortens
inquiry scan windows. Two phones each scanning in short, infrequent
windows can take a long time to coincide — which presents as "they never
find each other" rather than as an outright failure.

This is vendor firmware behaviour, not an API contract, so it varies by
handset. Present it as a plausible aggravating factor, not as the
explanation.

## How to tell which mechanism is actually biting

Useful because the two explanations predict different things, and this is
a question a marker may well ask. On the test handsets:

1. Turn **Wi-Fi off** but leave **Location on**, with the system's Wi-Fi
   scanning setting (variously "Wi-Fi scanning always available", "Improve
   location accuracy", or "Google Location Accuracy") **enabled**. Android
   can then still use Wi-Fi scanning for location with the radio nominally
   off.
   - Discovery **works** → the location pathway was the cause.
   - Discovery still **fails** → radio coexistence is contributing.
2. Turn **Location off** with **Wi-Fi on**. Discovery should fail. If it
   does, that confirms the location gate directly and independently of
   Wi-Fi.

This has not been run on the project's own handsets yet. Until it is, the
honest position is that the location gate is the documented and sufficient
explanation, and coexistence may add to it on specific hardware.

## What could remove the dependency

Recorded so the design decision is visible rather than looking like an
oversight.

- **Carry the MAC address over BLE.** The app already runs a BLE
  advertisement protocol that every peer scans, and the friend handshake
  already carries a rotating seed through manufacturer data (see CLAUDE.md,
  "Naming a Radar dot"). A MAC is six bytes. Exchanging it during the
  friend handshake would mean the first RFCOMM connection already has an
  address and would never need discovery at all — removing this
  dependency outright rather than explaining it.

  Not done yet, and it is the obvious next change in this area. It is also
  not free: a MAC address is a stable hardware identifier, and
  broadcasting one undoes some of the anti-tracking work the rotating
  presence token exists to do. It would need to go only to an accepted
  contact, which the friend-accept leg already is.
- **Ask for a bond.** Bonded devices can be connected to without
  discovery. Rejected deliberately and recorded in CLAUDE.md: secure
  RFCOMM triggers an OS-level pairing dialog on every connection, which
  was worse.

## One-paragraph version, for the viva

> Chat itself is pure Bluetooth — RFCOMM sockets, no IP and no internet.
> The first time two phones connect, though, neither knows the other's
> Bluetooth address, so the app has to run a classic Bluetooth discovery
> scan. Android treats a list of nearby devices as location data, so it
> only returns discovery results when Location is available, and Android's
> location service relies on Wi-Fi scanning to work indoors. With Wi-Fi
> off, location degrades and the scan silently returns nothing at all —
> no error, just no devices. So the Wi-Fi radio has to be on, though it
> never joins a network and we send no data over it. After one successful
> connection each phone has stored the other's address and connects
> straight to it, so discovery is skipped and the requirement never
> applies again.
