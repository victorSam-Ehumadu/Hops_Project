# Domain setup (hopsapp.me) and backing up the app itself

Two operational questions, answered together because the second one is
partly about the first.

---

## 1. Sending OTP emails from hopsapp.me

**No code change is needed.** `supabase/functions/_shared/send_email.ts`
already reads the sender from the `HOPS_EMAIL_FROM` secret, so this is
configuration plus DNS.

### Why this is worth doing beyond looking tidier

The project currently uses SendGrid **Single Sender Verification** — one
verified mailbox, no DNS. That works, but it has a real defect recorded in
`send_email.ts`: there is no domain-level authentication, so Gmail,
Outlook and Yahoo have no cryptographic reason to trust the sender, and
OTP emails land in spam. Nothing in the sending code can override a
filtering decision made on the recipient's side.

Owning `hopsapp.me` is what fixes that, via **Domain Authentication**
(SPF + DKIM). This is the difference between "the code sends the email"
and "the student actually receives it", and it is worth demonstrating: an
OTP that reliably arrives is a visible quality difference during a live
demo.

### Steps

1. In SendGrid: **Settings → Sender Authentication → Authenticate Your
   Domain**. Enter `hopsapp.me`. It generates three CNAME records.
2. Add those CNAMEs at your domain registrar exactly as given. They look
   like:

   | Type | Host | Points to |
   |---|---|---|
   | CNAME | `em1234.hopsapp.me` | `u1234567.wl.sendgrid.net` |
   | CNAME | `s1._domainkey.hopsapp.me` | `s1.domainkey.u1234567.wl.sendgrid.net` |
   | CNAME | `s2._domainkey.hopsapp.me` | `s2.domainkey.u1234567.wl.sendgrid.net` |

   The exact values are generated per account — use the ones SendGrid
   shows you, not these.
3. Click **Verify**. DNS propagation is usually minutes but can take up to
   48 hours.
4. Add a DMARC record so receivers know what to do with mail that fails
   the checks above. Start permissive and tighten once you have confirmed
   real mail passes:

   | Type | Host | Value |
   |---|---|---|
   | TXT | `_dmarc.hopsapp.me` | `v=DMARC1; p=none; rua=mailto:dmarc@hopsapp.me` |

   `p=none` only monitors. Move to `p=quarantine` after a week of clean
   reports — going straight to `p=reject` risks silently dropping your own
   OTP mail during the demo period.
5. Point the function at the new sender:

   ```
   supabase secrets set HOPS_EMAIL_FROM="Hops <no-reply@hopsapp.me>"
   ```

   `no-reply@` is deliberate: nothing in the app reads replies, and a
   mailbox nobody monitors is worse than one that is named as unmonitored.
   The appeals address (`HOPS_APPEALS_EMAIL`, see the functions README) is
   separate and **should** be a real monitored mailbox, since a banned
   student needs somewhere to appeal to.
6. Send one real OTP to a Gmail address and confirm it arrives in the
   inbox rather than spam. That is the only check that matters.

---

## 2. "A backup for the app itself"

### Short answer: Vercel is the wrong tool, and it is worth being clear why

Vercel hosts web applications. Hops is a **Flutter Android app** — the
deliverable is an APK that runs on a phone, with a BLE mesh data plane
that has no server side at all. There is nothing for Vercel to run.

It is the right host for exactly one thing already in this repo: the
static marketing site in `website/`. That is useful, but it is not a
backup of the app.

Worth separating two things your supervisor may mean, because they need
different answers:

| What "backup" could mean | What it needs |
|---|---|
| The app can be recovered if a laptop dies | Source + build artifacts preserved off-machine |
| The app keeps working if something fails during the demo | A spare installable APK and a rehearsed fallback |

Both are worth having, and neither is Vercel.

### 2a. Recovering the project

Three layers, cheapest first. The first two already exist.

1. **Source: GitHub.** Already in place. This is the real backup of the
   app — every line of code, every migration, and the full history.
   Confirm the current branch is pushed before the presentation.
2. **Database: `scripts/backup-db.ps1`.** Already in place, and the
   restore has been verified (see CLAUDE.md). The Supabase database is the
   only state that does not live on a device.
3. **Build artifacts: a tagged GitHub Release.** This is the gap.

   Source alone is not quite enough. Rebuilding an APK needs the right
   Flutter version, the dependencies resolving the same way, and — the
   part that actually bites — `client/.env`, which is gitignored and
   therefore in no backup at all. A signed APK attached to a release is
   recoverable in seconds and needs no toolchain:

   ```
   cd client
   flutter build apk --release
   gh release create v1.0-phase5 build/app/outputs/flutter-apk/app-release.apk \
       --title "Phase 5 submission build" \
       --notes "Build demonstrated for Phase 5."
   ```

   **Keep a copy of `client/.env` somewhere safe and off GitHub** — a
   password manager or an encrypted note. It holds the Supabase URL and
   anon key, it is deliberately gitignored, and without it the app will
   not build. This is the single most likely thing to be missing when
   someone tries to rebuild from a clean clone.

### 2b. Surviving the demo

Separate problem, and the one more likely to matter on the day.

- **Put the release APK on a USB stick and in cloud storage**, so a phone
  can be reflashed in the room without a build.
- **Install on more than one phone before the day.** Both halves of every
  peer feature need two devices; a single phone failing takes the whole
  demo with it.
- **Record a short screen capture of each feature working.** The practice
  pack already has demo-failure wording
  (`Group 18 Presentation Practice Pack.docx`); a video is what makes that
  wording credible rather than an excuse. BLE in a room full of laptops
  and phones is genuinely unpredictable — it is the one part of this
  project that can fail for reasons nobody in the room controls.
- **Note what needs connectivity and what does not.** Sign-in, OTP email
  and moderation need the internet. Everything peer-to-peer does not. If
  campus Wi-Fi fails, sign in beforehand and stay signed in — and
  remember the first 1:1 chat connection needs Wi-Fi switched on at both
  ends (`report-rfcomm-wifi-dependency.md`).

### 2c. If a hosted deployment is genuinely required

If the requirement really is "show it deployed somewhere", the honest
options are:

- **A download page on `website/`, hosted on Vercel**, serving the release
  APK. This is a legitimate use of Vercel, it uses the domain you already
  own, and it is a real distribution channel for an Android app. If
  someone asked for "the app on Vercel", this is almost certainly the
  useful version of that request.
- **Flutter web build** — technically possible, but it would not work.
  Every Bluetooth mechanism in Hops (BLE advertising, RFCOMM, Nearby
  Connections) is unavailable in a browser, so a web build would be a
  non-functional shell of the UI. Do not present it as the app.

**Recommendation:** tagged GitHub Release for recovery, plus an APK
download page on `hopsapp.me` via Vercel for the "it is deployed"
requirement. Say plainly that the app is an Android package rather than a
web app — that is a correct architectural consequence of an offline-first
BLE mesh, not a gap.
