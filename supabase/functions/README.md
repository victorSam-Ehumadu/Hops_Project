# Hops Edge Functions

Two functions, both purely "generate a one-time code and email it" — the
actual verification (does the code match?) happens entirely in Postgres via
RPCs in `supabase/migrations/0007_email_auth_and_otp.sql`, so these are the
only two places in the whole backend that make an outbound network call.

- `send-password-reset-otp` — forgot-password flow
- `send-verification-email` — signup / change-email verification

Both send through [Resend](https://resend.com) by default (see
`_shared/send_email.ts`) purely because it needs nothing but an API key to
get started — swap in SendGrid/Postmark/SES/etc. by editing that one file;
nothing else needs to change.

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

3. Sign up at [resend.com](https://resend.com) (free tier is plenty for
   this), grab an API key, then:
   ```
   supabase secrets set RESEND_API_KEY=re_your_key_here
   ```
   Optionally also set a custom "From" address once you've verified a
   sending domain in Resend (until then, sending only actually reaches the
   Resend account's own verified email address):
   ```
   supabase secrets set HOPS_EMAIL_FROM="Hops <noreply@yourdomain.com>"
   ```

4. Deploy both functions:
   ```
   supabase functions deploy send-password-reset-otp
   supabase functions deploy send-verification-email
   ```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` don't need to be set manually
— Supabase injects those into every Edge Function automatically.

## Testing without a real inbox

Resend's sandbox sender (`onboarding@resend.dev`, the default in
`send_email.ts`) will only actually deliver to the email address on the
Resend account you signed up with — handy for testing the whole flow
end-to-end before verifying a real domain.
