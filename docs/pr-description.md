# Pull request #1 — title and body

Paste these into https://github.com/victorSam-Ehumadu/Hops_Project/pull/1
(click **Edit** beside the title). The existing body describes only the
first five commits; the branch now carries 72.

---

## Title

```
Phase 4 and 5 material, a rebuilt site and deck, and the safety fixes found along the way
```

---

## Body

```markdown
72 commits. The documents and the app fixes are related: writing up the
testing sections and rehearsing the demo is what surfaced most of the bugs.

## Safety-critical fixes

**Emergency Flares did not ring when the phone was idle.** The foreground
service was declared `dataSync` while its own comment called it "Foreground
service for continuous BLE scanning". From Android 14 a foreground service
that uses Bluetooth must declare `connectedDevice`; scanning from a
dataSync-only service is not a permitted use of that type. Now
`connectedDevice|dataSync` — dataSync kept for the identity poll and
deliberately not alone, since Android 15 caps a dataSync service near six
hours a day and then stops it. *Not device-verified; needs a phone on
Android 14+.*

**The admin app could not tell a failed broadcast from a sent one.**
`startAdvertising()` posts to a Handler and returns immediately, so the
verdict only arrives on `onStartFailure`. `AdminBleHub` never registered
that callback: the await succeeded, a msgId came back, the alert appeared
in the admin's own list, and nothing had left the radio. It now registers
the callback, waits for the verdict before claiming success, refuses an
over-long name outright, and reports why — plumbed into the composer's
snackbar, which previously guessed "check Bluetooth is on" even when
Bluetooth was on and the message was simply too long.

**Alerts over ~10 characters never arrived.** Not a chunk-count problem —
the chunking round-trips at every length (new test). A chunk-size problem:
a chunk's name is 13 + text, so 11 characters produced the first *full*
chunk at 24 bytes, putting that handset's real ceiling at 23, below the 26
this codebase computes. `kCommunityNameBudget` 24 → 22. Second time this
number has been too high; the first was 27.

**Every Community Alert arrived twice.** Two independent causes. The sender
tag was derived in five places and one — the server post — truncated
without padding, so `victor` and `victor__` never matched the
`(senderTag, msgId)` dedup. And the local copy was backfilled by list
index, which `_mergeServerAlerts` invalidates by re-sorting; a multi-part
alert spends seconds per part, ample time for the 30s poll to fire
underneath it. One `communitySenderTag()` now, and identity-based backfill.

**Notification spam after a cancel.** `liveAlerts` is keyed by sender,
which dedups sightings but is not enough to decide whether to *notify*:
entries leave that map on a stand-down and on the stale prune, so the next
relayed sighting looked new. A flare is relayed by every phone that heard
it, so those kept arriving after the sender stood down.

## Moderation and accounts

- **Reporter flagging.** `profiles.reporter_flagged_at` has existed since
  0015 with an automatic trip and a clear action, but nothing could ever
  set it by hand — a "forgive" with no "act". `0025` adds
  `admin_flag_reporter`, idempotent on the timestamp.
- **Take Action from a report**, opening the account screen's own sheet
  rather than a second copy of it, with the flag entry pointed at the
  *reporter* while every other action targets the reported user.
- **Export offered before Log Out and Delete Account**, since both erase
  the device and no server copy exists.
- The watched person can now **end a Watch Me**, via a new `WX:`
  advertisement sent by either side. Consent could previously be given but
  not withdrawn.

## Features and UI

- **Study Bunny venues** renamed to Venue 1–14, Student Pods, Auditorium,
  Benches. A rename in place — index 0 is still index 0 — but an older
  build shows the old name for the same index, so the APK needs
  re-publishing before mixing builds.
- **Vibe Check** picks a venue from the same list plus Lab 1–3 and
  Reception, instead of free text that could never be grouped. Its location
  travels as text, not an index, so the list stays free to change.
- **Day separators** in the Action Log, Community Alerts and 1:1 chat, from
  one shared helper that compares calendar dates rather than elapsed hours.
- **Action Log** gains a time window and action-type filters, collapsed
  into two dropdowns, and the Dashboard's card styling. Found while wiring
  it: `suspend`/`unsuspend` have been logged since 0015 but no describer
  knew them.

## Website and deck

- The site gets a real design system, dark mode, and donations priced in
  **rands** (R20/R50/R100, not a symbol swap — the old tiers were dollars).
  Two bugs the dark theme exposed: a logo whose transparency had been
  flattened onto a white disc, and a CTA band that inverted into a
  gradient no single text colour could sit on.
- The 5-minute deck cut from ten slides to six, then a demo-setup slide
  added. Four of the ten were one idea told four times. Also restored the
  outro video's playback timing, which an earlier animation pass had
  stripped.

## Verification

- `flutter test` — **281 tests**, all green (was 115 at the branch point).
- `flutter analyze lib/` — the documented 3-info baseline, unchanged.
- Nothing in the BLE, RFCOMM or Nearby paths is device-verified. The
  budget change and the foreground-service type both need two physical
  phones to confirm.

## Before merging

Migrations **0023**, **0024** and **0025** are written but not applied.
Until 0025 is live the new Flag button fails, because
`admin_flag_reporter` does not exist.
```
