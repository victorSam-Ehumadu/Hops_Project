# What you need to do

Everything outstanding from the work so far, in the order that unblocks
the most. Tick as you go.

Nothing in the app is broken while these are pending — but several
features are **code-complete and server-incomplete**, which looks
identical to a bug from the outside.

---

> **One thing about the Supabase SQL Editor, since it keeps catching
> people:** when a script contains several statements, it displays only the
> **last** result set. So a two-statement script looks like it only did one
> thing, and a report query pasted after another query seems to return
> nothing. Nothing is actually wrong — but it means you should verify with
> a separate `select` rather than trusting what the editor shows, and run
> report queries one at a time by selecting just those lines before
> pressing Run.

## 1. Database — do this first, nothing else depends on itself

Migrations written and committed but **not applied** are listed below.
Until they are, the features they back silently do nothing.

**Still outstanding: `0023`, `0024`, `0025`.**

- [ ] **Apply `0025_manual_reporter_flag.sql`** — adds `admin_flag_reporter`
      and lets the log accept the new `flag_reporter` action. Without it,
      the "Flag for wrongful reporting" entry now on both Take Action
      sheets fails with "not authorized"-shaped errors, because the
      function does not exist. The flag column itself has been there since
      `0015`; only a manual way to SET it was missing.

- [x] **Run the probe first.** Supabase dashboard → your project → **SQL
      Editor** → New query. Paste `supabase/check-applied-migrations.sql`.
      Read-only, safe any time. It tells you exactly which of 0001–0022
      are live.

      The file holds **two** queries, and the Supabase editor shows only
      the *last* result set when several run together — so highlight
      Query 1 (lines 50–210, ending `order by seq;`) and press Run on
      just that. Banners in the file mark where each one starts.
- [ ] **Check for duplicate usernames.** The probe's second query lists
      them. `0020` refuses to run while any exist — deliberately, since
      choosing which of two accounts named `victor` is real is your call,
      not a migration's. Delete or rename the extras.
- [x] **Apply `0020_username_uniqueness_and_standing_enforcement.sql`.**
      This is the one that makes **suspend and ban actually work** — until
      it is applied, a suspended user can sign straight back in. Also stops
      duplicate usernames.
- [x] **Create two Vault secrets** *before* `0021`, or it adds the columns
      and skips the backfill. `alter database ... set` does NOT work on
      Supabase — the `postgres` role is not a superuser and it fails with
      `42501 permission denied to set parameter`. Use Vault:
      ```sql
      select vault.create_secret(
               encode(extensions.gen_random_bytes(32), 'hex'),
               'hops_email_encryption_key',
               'Hops: symmetric key for profiles.email_encrypted');

      select vault.create_secret(
               encode(extensions.gen_random_bytes(32), 'hex'),
               'hops_email_blind_index_key',
               'Hops: HMAC key for profiles.email_lookup');
      ```
      The key is generated inside the database, so it never passes through
      a clipboard or chat window. No new session needed — it is table data.
- [x] **Verify both exist** (two rows expected):
      ```sql
      select name, created_at from vault.decrypted_secrets
       where name like 'hops_email_%';
      ```
- [ ] **Record both keys off the database** — password manager, not the
      repo:
      ```sql
      select name, decrypted_secret from vault.decrypted_secrets
       where name like 'hops_email_%';
      ```
      Vault is the safer store, but its master key belongs to **this**
      Supabase project. Restore a dump into a different project — which is
      what `verify-backup.ps1` does locally — and `email_encrypted` cannot
      be decrypted there. With the hex recorded you can set it as a GUC on
      the restore target; without it that data is gone.
- [x] **Apply `0021_institutional_email_and_email_encryption.sql`.**
      Restricts signup to `@my.richfield.ac.za` and encrypts email at rest.
- [x] **Apply `0022_admin_statistics.sql`.** The charts and rankings.
- [ ] **Re-run the probe.** Rows `0021 (d)` and `(e)` matter most: `(d)`
      confirms the keys are set, `(e)` confirms the backfill actually ran.
      Columns existing is *not* the same as email being encrypted.

---

## 2. Domain — hopsapp.me

Two independent jobs on the same domain. Details in
`docs/deployment-domain-and-backup.md`.

### Email sending — now Resend, not SendGrid

The SendGrid trial expired into `401 Maximum credits exceeded`, and the
Single Sender advantage that justified choosing it stopped mattering once
`hopsapp.me` was verified. `_shared/send_email.ts` was rewritten for
Resend (free tier 3,000/month); `sendEmail()`'s signature is unchanged so
the three functions were untouched.

- [x] ~~SendGrid domain authentication~~ — superseded.
- [x] **Resend → Domains → Add Domain → `hopsapp.me`.** Add every DNS
      record it lists. Same Namecheap Host-field rules as before (§1b of
      `deployment-domain-and-backup.md`).
- [ ] **Remove the old SendGrid CNAMEs** from Namecheap once Resend
      verifies — the `em…` and `s1/s2._domainkey` rows. Harmless if left,
      but they are dead records pointing at an expired account.
- [x] **Create a Resend API key** (API Keys → Create, Sending access) and
      set it:
      ```
      RESEND_API_KEY = re_your_key_here
      ```
      Via **Project Settings → Edge Functions → Secrets** if you have no
      CLI. Raw value — no shell quotes.
- [x] **Deploy all three functions** after any `_shared/send_email.ts`
      change — the bundler inlines it, so a local edit does nothing until
      each is redeployed. This is what made the Resend switch look broken.
      `npx --yes supabase@latest functions deploy <name> --project-ref <ref>`
      from the repo root, in your own PowerShell (`supabase login` needs a
      real terminal).
- [ ] **Delete the now-unused `SENDGRID_API_KEY` secret** so a stale
      credential is not left configured.
- [ ] Add the DMARC TXT record at `_dmarc.hopsapp.me`, starting with
      `p=none`.
- [x] `supabase secrets set HOPS_EMAIL_FROM="Hops <no-reply@hopsapp.me>"`
- [x] Send one OTP to a Gmail address and confirm it lands in the **inbox,
      not spam**. That is the only check that matters — and the thing this
      whole step buys you, since Single Sender Verification has no domain
      authentication and OTPs currently get filtered.
- [ ] Set `HOPS_APPEALS_EMAIL` to a mailbox someone actually reads. A
      banned student needs somewhere to appeal to.
- [ ] *Later:* move DMARC to `p=quarantine` after a week of clean reports.
      Do not jump to `p=reject` before the demo — it can silently drop your
      own OTP mail.

### Email quota — a real demo-day risk

SendGrid's free plan caps daily sends (typically 100). Exceeding it returns
`401 Maximum credits exceeded`, which surfaces in the app as "Couldn't send
the code — the mail server rejected it" and looks exactly like a
misconfiguration. It is not: check
**SendGrid → Settings → Account Details** and the Activity Feed before
debugging anything.

- [ ] **Create the demo accounts before presentation day.** Once signed in,
      nothing in the app touches email again — the entire BLE side is
      unaffected by the quota.
- [ ] **Know what degrades.** Email verification is skippable by design
      (the error screen offers *Skip for now*) so an account still works
      without it. **Forgot Password is not** — it needs a live OTP. Demo
      that early in the session, or from a recording.
- [ ] **Count the sends you will need.** Each sign-up is one email, each
      password reset one, each ban/suspend notice one. Rehearsing the
      moderation flow repeatedly is the likeliest way to burn the day's
      allowance before the demo starts.

### Website hosting

- [ ] Deploy `website/` to Vercel. **Root Directory must be `website`**,
      Framework Preset *Other*, build command empty — otherwise it tries to
      build the Flutter app. `website/vercel.json` handles the rest.
- [ ] Add `hopsapp.me` and `www.hopsapp.me` in Vercel → Settings → Domains,
      then add the records it shows at your registrar.
- [ ] **If you delegate nameservers to Vercel, re-create the SendGrid and
      DMARC records there.** Miss this and email keeps *sending* but stops
      being trusted — it fails quietly, which is the worst kind.

---

## 3. The APK download

- [x] **DONE 2 Nov 2026 — repo made public, Release published.** The
      download link now returns 200 and serves 65.9 MB anonymously.
      Release `v1.0-phase5`, asset `hops.apk`, not a pre-release.
- [x] **Decide: public or private repo.** The download page links to
      `releases/latest/download/hops.apk`, and **release assets on a
      private repo are not publicly downloadable** — the link 404s.
  - Making it public? First check history for secrets:
    ```
    git log --all --name-only | sort -u | grep -iE 'env|secret|key|backup'
    ```
    (`client/.env` and `backups/` are gitignored, so you are probably
    clean — but history keeps anything ever committed, even if deleted.)
  - Staying private? Put the APK at `website/assets/hops.apk` and change
    the link to `/assets/hops.apk`. `vercel.json` already serves it with
    the right content type.
      **Confirmed broken as of 2 Nov 2026**: the live link returns 404, and
      the repo is private, so it has never worked. Decision taken: go
      public and publish a Release.
      History was scanned on 2 Nov 2026 — `client/.env` was never
      committed, no keystore or credentials file is tracked, and no
      JWT-shaped string appears in any of the 839 blobs in history. The
      only matches for "service role" are `Deno.env.get(...)` reads in the
      edge functions, which are env lookups, not secrets.
- [x] **Uploaded.** The build is at `client/build/hops.apk`
      (66 MB, 2 Nov 2026). `client/build/` is gitignored, so it will not
      be committed by accident — upload it to the Release by hand, named
      exactly `hops.apk`, or the `releases/latest/download/hops.apk` link
      will not resolve.
- [ ] To rebuild it later:
      ```
      cd client
      flutter build apk --release
      cp build/app/outputs/flutter-apk/app-release.apk build/hops.apk
      ```
      Note `--split-per-abi` is NOT used: one universal APK means nobody
      has to know which ABI their phone is. About a third of the size is
      `x86_64`, which only emulators run — `--target-platform
      android-arm,android-arm64` does **not** remove it (it still ships in
      the output), so dropping it needs `abiFilters` in `build.gradle.kts`
      if the size ever matters.
- [ ] **Know what the signing means.** `android/app/build.gradle.kts` maps
      the release build to the **debug** keystore. That is fine for
      sideloading and is why the build needs no secrets — but it is not a
      stable identity. If a real keystore is ever introduced, every
      existing install must be uninstalled before it can update, because
      Android refuses an update signed by a different key.
- [ ] **Back up `client/.env` off GitHub.** It is gitignored, so it is in
      no backup at all, and the app will not build without it. This is the
      single most likely thing to be missing if anyone rebuilds from a
      clean clone.

---

## 4. Testing on two phones

None of the Bluetooth work is device-verified — it cannot be from here.
Do these after the migrations are applied.

- [ ] **Suspend and ban, end to end.** Suspend from the admin app, confirm
      the student lands on the sign-in page within ~30s, then confirm they
      **cannot sign back in**. The sign-in half needs `0020`.
- [ ] **Also test it on an admin account.** A suspended admin used to keep
      every moderation power, including acting on whoever suspended them.
- [ ] **Vibe Check and Study Bunny across two phones** — the silent-failure
      fix. Try a deliberately long location name and confirm you now get a
      visible warning instead of nothing happening.
- [ ] **Radar dot naming.** Contacts added *before* this fix have no seed
      stored and will still show anonymous — nothing retransmits one.
      **Re-add your demo contacts**, or open one 1:1 chat with each, before
      the presentation.
- [ ] **Read receipts** — single tick → double tick when the other person
      opens the thread.
- [ ] **Study Bunny location** — pick a location on one phone, confirm it
      appears on the other.
- [ ] **Forgot password** with a real email, end to end.
- [ ] **First 1:1 chat connection** with Wi-Fi on at both ends, to confirm
      the hint behaves and self-dismisses.

---

## 5. Before real users — not before the demo

Leave these as they are for the presentation; they exist to make the demo
work.

- [ ] **Empty the test email allowlist, in BOTH places** — either one alone
      still admits a signup:
      - `client/lib/utils/password_policy.dart` → `kTestEmailAllowlist`
      - `supabase/migrations/0021_…sql` → `v_allowlist`
- [ ] **Turn off unlimited carrots.**
      `client/lib/services/carrot_wallet.dart:35` →
      `debugUnlimitedCarrots = false`. Currently `true` for the demo.
- [ ] **Revert `0009`'s email relaxation** — re-add the unique index so two
      accounts cannot share an email. Steps are in that file's "TO REVERT"
      section. Note it also makes forgot-password deterministic, which it
      currently is not for shared addresses.
- [ ] **Finish the email encryption** by dropping the plaintext column.
      Encryption at rest is only actually achieved once it is gone.
      `0021` section 8 has the verification steps and the list of readers
      to rewrite first. It is a one-way change, so it is deliberately not
      automatic.

---

## 6. Project admin

- [ ] **Open the PR** for `phase-4-5-and-safety-fixes`. Everything is
      pushed; `gh` is not installed here so I could not open it.
- [ ] **Phase 4 and Phase 5 have no generators.** The deck and practice
      pack do (`docs/generators/`), those two do not — edit the `.docx`
      directly, or ask and I will build generators for them.
- [ ] **Re-check the figure counts** in the deck and practice pack if you
      quote them. Test count has moved (125 → 212) and several features
      changed this session.
- [ ] **Export any edited `.docx` to PDF and read it** before calling it
      done — that has caught a struck-through title, blank pages and table
      widows before.

---

## Quick reference: what is blocked on what

| If you only do one thing | Do this |
|---|---|
| Make moderation work | Apply `0020` |
| Make OTP email arrive | SendGrid Domain Authentication |
| ~~Make the download link work~~ | **Done** — repo public, `v1.0-phase5` published, link returns 200 |
| Protect the demo | Re-add demo contacts; tag a release APK |
