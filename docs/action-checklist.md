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

Three migrations are written and committed but **not applied**. Until they
are, the features they back silently do nothing.

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

### Email sending

- [x] SendGrid → **Settings → Sender Authentication → Authenticate Your
      Domain** → `hopsapp.me`. Add the three CNAMEs it generates at your
      registrar, then Verify.
- [ ] Add the DMARC TXT record at `_dmarc.hopsapp.me`, starting with
      `p=none`.
- [ ] `supabase secrets set HOPS_EMAIL_FROM="Hops <no-reply@hopsapp.me>"`
- [ ] Send one OTP to a Gmail address and confirm it lands in the **inbox,
      not spam**. That is the only check that matters — and the thing this
      whole step buys you, since Single Sender Verification has no domain
      authentication and OTPs currently get filtered.
- [ ] Set `HOPS_APPEALS_EMAIL` to a mailbox someone actually reads. A
      banned student needs somewhere to appeal to.
- [ ] *Later:* move DMARC to `p=quarantine` after a week of clean reports.
      Do not jump to `p=reject` before the demo — it can silently drop your
      own OTP mail.

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

- [ ] **Decide: public or private repo.** The download page links to
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
- [ ] Build and publish, named exactly `hops.apk`:
      ```
      cd client
      flutter build apk --release
      cp build/app/outputs/flutter-apk/app-release.apk hops.apk
      gh release create v1.0-phase5 hops.apk --title "Phase 5 submission build"
      ```
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
| Make the download link work | Decide public repo, or self-host the APK |
| Protect the demo | Re-add demo contacts; tag a release APK |
