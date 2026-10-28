# Hops Edge Functions

Three functions — every outbound network call this backend makes. The first
two are purely "generate a one-time code and email it"; the actual
verification (does the code match?) happens entirely in Postgres via RPCs in
`supabase/migrations/0007_email_auth_and_otp.sql`. The third notifies a
student their account status changed, after the Postgres side (ban_user/
suspend_user/etc., `0016_moderation_email_and_log_detail.sql`) already did
the actual work — same shape as the other two: the client calls this only
after the database call it depends on has already succeeded.

- `send-password-reset-otp` — forgot-password flow
- `send-verification-email` — signup / change-email verification
- `send-moderation-email` — ban/suspend/reinstatement notice, with an
  appeal path on the two restrictive kinds (see `HOPS_APPEALS_EMAIL` below)

All three send through [Resend](https://resend.com) (see
`_shared/send_email.ts`) — free tier 3,000 emails/month, sending from the
project's own verified domain. Swap in Postmark/SES/SendGrid/etc. by
editing that one file; nothing else needs to change, and `sendEmail()`'s
signature is kept stable precisely so a provider change stays confined
there.

This was SendGrid until the switch, for a reason that no longer holds:
SendGrid's Single Sender Verification let you send from one ordinary
mailbox with no domain and no DNS, which was the only option before the
project owned a domain. Now that `hopsapp.me` is set up and DNS-verified,
Resend's domain requirement costs nothing and its allowance is far larger
— and the SendGrid trial had expired into `401 Maximum credits exceeded`
anyway.

## When sending stops working

Check the function's logs first
(`/dashboard/project/<ref>/functions/<name>/logs`) — `send_email.ts` logs
the provider's exact response, and the three failure kinds need different
responses:

| Log line | Meaning | Action |
|---|---|---|
| `429`, or text mentioning quota/limit | allowance or rate limit | none — resolves itself |
| `403` | sending domain not verified | fix it in Resend → Domains |
| `RESEND_API_KEY is not set` | secret missing | set it |

The app distinguishes these too, via the `error` field alongside
`{ok: false}` — `quota_exceeded`, `sender_not_verified`,
`email_not_configured` (see `describeEmailSendFailure` on the Dart side).
Worth having, because the previous single message — "the mail server
rejected it" — pointed at the sender for all of them, and a SendGrid quota
exhaustion consequently had DNS and the From address audited at length
while both were entirely correct.

Resend also rate-limits to 2 requests/second, which also surfaces as 429.
Unlikely here (one email per user action) but it is the same code.

Worth knowing before a live demonstration: sign-up and password reset each
cost one send, as does every ban/suspend notice. Rehearsing the moderation
flow is the easiest way to exhaust the allowance before an audience sees
it. Email verification is skippable by design and an account works without
it; password reset is not.

## One-time setup

1. Run the new migration against your Supabase project (same as every
   other file in `supabase/migrations/` — SQL editor, or `supabase db push`
   if you're using the CLI with a linked project):
   `0007_email_auth_and_otp.sql`

2. Get the CLI. No install needed if Node is present — `npx --yes
   supabase@latest <cmd>` works and is what this project uses.

   **Authenticate with a personal access token, not `supabase login`.**
   The login flow opens a browser and requires an interactive terminal, so
   it fails with `LoginMissingTokenError: Cannot use automatic login flow
   inside non-TTY environments` under any wrapped or scripted shell —
   including an agent session. Create one at
   https://supabase.com/dashboard/account/tokens, then **in your own
   PowerShell window**:
   ```powershell
   cd C:\Projects\Hops_Project
   $env:SUPABASE_ACCESS_TOKEN = "sbp_your_token_here"
   ```
   One window for all the commands below, because the variable only lives
   for that session.

   `$env:` rather than passing `--token` on each command for the same
   reason `scripts/backup-db.ps1` reads its URI via `Read-Host`: Windows
   PowerShell appends every typed command to `ConsoleHost_history.txt`
   permanently, so a token in an argument is written to disk for good.

   `--project-ref <ref>` on each command avoids needing `supabase link`.

3. Sign up at [resend.com](https://resend.com). Under **Domains → Add
   Domain**, add `hopsapp.me` and create the DNS records it shows —
   `docs/deployment-domain-and-backup.md` §1b has the Namecheap
   click-by-click, including the Host-field rule that silently breaks
   verification. Then **API Keys → Create** with Sending access:
   ```
   supabase secrets set RESEND_API_KEY=re_your_key_here
   supabase secrets set HOPS_EMAIL_FROM="Hops <no-reply@hopsapp.me>"
   ```
   `HOPS_EMAIL_FROM` is required and its domain must be the verified one —
   Resend returns 403 otherwise, so there is no working default to fall
   back on if it is unset. Either `Name <addr@domain>` or a bare
   `addr@domain` works; Resend takes the combined string directly.

   Setting these through the dashboard instead
   (**Project Settings → Edge Functions → Secrets**) works equally well
   and needs no CLI — but note the value there is raw, so do **not**
   include the shell quotes shown above.

   And for `send-moderation-email` specifically, an inbox that actually
   reads appeals — without this, "reply to this email to appeal" in a ban/
   suspend notice is a promise nobody's checking:
   ```
   supabase secrets set HOPS_APPEALS_EMAIL=appeals@yourdomain.com
   ```

4. Deploy all three functions:
   ```
   npx --yes supabase@latest functions deploy send-password-reset-otp --project-ref <ref>
   npx --yes supabase@latest functions deploy send-verification-email --project-ref <ref>
   npx --yes supabase@latest functions deploy send-moderation-email   --project-ref <ref>
   ```

   **All three, every time `_shared/send_email.ts` changes.** The bundler
   inlines that file into each function, so editing it locally changes
   nothing until each one is redeployed — and a function still running the
   previous bundle will report the previous provider's errors. That is
   exactly how the SendGrid-to-Resend switch appeared not to work: the
   secret had been updated, but the deployed code was still asking for
   `SENDGRID_API_KEY`.

   Run these from the repo root, not from `client/`.

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` don't need to be set manually
— Supabase injects those into every Edge Function automatically.

## Testing without a real inbox

Resend does provide a sandbox sender, `onboarding@resend.dev`, which needs
no domain — but it only ever delivers to the Resend account's **own**
address, so it cannot be used to test what a student receives. It is
useful for confirming the key and the function wiring work, nothing more.

With `hopsapp.me` verified there is little reason to use it: set
`HOPS_EMAIL_FROM` to the real sender and test end-to-end. When you do,
check the delivered message's **Authentication-Results** header (Gmail:
⋮ → Show original) rather than only that it arrived:

```
SPF:   PASS
DKIM:  PASS
DMARC: PASS
```

All three passing is the goal. "It arrived" can be true of mail that only
just escaped the spam folder, and a DKIM failure alongside an SPF pass
points straight at a `_domainkey` record.
