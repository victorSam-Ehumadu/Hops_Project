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

All three send through [SendGrid](https://sendgrid.com) by default (see
`_shared/send_email.ts`) — its free tier's Single Sender Verification means
you can send to any recipient after verifying one email address you
already own, no domain/DNS required. Swap in Postmark/SES/Resend/etc. by
editing that one file; nothing else needs to change.

## When sending stops working

`401 {"errors":[{"message":"Maximum credits exceeded"}]}` in a function's
logs is the free plan's daily send cap, not a configuration fault. The app
surfaces it as "Couldn't send the code — the mail server rejected it",
which reads like a broken sender and sends you auditing DNS for no reason.
Check **SendGrid → Settings → Account Details** and the Activity Feed
first. The quota resets daily.

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

2. Install the [Supabase CLI](https://supabase.com/docs/guides/cli) if you
   haven't already, then from the repo root:
   ```
   supabase login
   supabase link --project-ref <your-project-ref>
   ```

3. Sign up at [sendgrid.com](https://sendgrid.com) (free tier is plenty for
   this). Under Settings > Sender Authentication, verify a **Single
   Sender** — the one email address you'll send from (a normal inbox you
   own, e.g. Gmail; no domain purchase or DNS records needed). Create an
   API key under Settings > API Keys (Mail Send permission is enough),
   then:
   ```
   supabase secrets set SENDGRID_API_KEY=SG.your_key_here
   supabase secrets set HOPS_EMAIL_FROM="Hops <you@example.com>"
   ```
   `HOPS_EMAIL_FROM` is required, and must exactly match the address you
   verified as a Single Sender — SendGrid rejects sends from anything
   else, so there's no working default to fall back on if it's unset.

   And for `send-moderation-email` specifically, an inbox that actually
   reads appeals — without this, "reply to this email to appeal" in a ban/
   suspend notice is a promise nobody's checking:
   ```
   supabase secrets set HOPS_APPEALS_EMAIL=appeals@yourdomain.com
   ```

4. Deploy all three functions:
   ```
   supabase functions deploy send-password-reset-otp
   supabase functions deploy send-verification-email
   supabase functions deploy send-moderation-email
   ```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` don't need to be set manually
— Supabase injects those into every Edge Function automatically.

## Testing without a real inbox

There isn't a sandbox sender to fall back on here the way some providers
offer — `HOPS_EMAIL_FROM` must be a verified Single Sender before any send
will succeed at all (SendGrid returns a 403 otherwise). Verifying one email
address you already own takes about two minutes (click the confirmation
link SendGrid emails you), so there's little reason not to just do that
first and test end-to-end for real.
