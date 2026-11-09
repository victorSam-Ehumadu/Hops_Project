-- ---------------------------------------------------------------------------
-- 0028 — put public.profiles.email back.
--
-- WHY
--
-- 0026 was applied. It was not meant to be: its own header calls it
-- irreversible and gates it on both Vault keys living off the database, and
-- CLAUDE.md records it as deliberately unapplied. It dropped
-- profiles.email.
--
-- 0026 rewrote the nine SQL functions that read that column. It did not
-- touch the three Edge Functions, which still do:
--
--   send-verification-email   .select("id, email, token_expires_at")
--   send-password-reset-otp   .select("id, email").ilike("email", ...)
--   send-moderation-email     .select("email")
--
-- PostgREST errors on a column that does not exist, so each of those got a
-- null row back, took its "no such profile" branch, and returned
-- invalid_session. The app matched that string and told people
-- "Your session has expired — please sign in again."
--
-- Nothing was wrong with anybody's session. What actually broke:
--
--   * signup could not send its verification code
--   * forgot-password could not send a reset code
--   * warning and ban emails were never sent
--
-- NOTHING WAS LOST. 0021's email_encrypted still holds every address, and
-- decrypt_email() still reads it. This migration restores the plaintext
-- column from that ciphertext.
--
-- WHY NOT FIX THE EDGE FUNCTIONS INSTEAD
--
-- That is the better end state and it is where 0026 was heading: no
-- plaintext address at rest. It is also three function rewrites plus three
-- deployments, days before a demo, on the paths that let people sign up and
-- recover an account. This restores the state everything already expects,
-- and costs one migration and no redeploys. When the Edge Functions are
-- ready to read via decrypt_email, 0026 can be applied properly — and it
-- will need a 0029 to drop this trigger first.
--
-- NO UNIQUE CONSTRAINT IS RESTORED. profiles_email_unique was dropped by
-- 0009 so a handful of test addresses could be shared, long before 0026.
-- That is also why 0026's `drop column ... restrict` succeeded: by then
-- nothing depended on the column. Re-adding uniqueness here would be a
-- different decision from the one this file exists to undo, and it would
-- fail outright on whatever duplicates 0009 was protecting.
--
-- SAFE TO RE-RUN. Every step is guarded.
-- ---------------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------------
-- 0. Refuse to run if the addresses cannot actually be recovered.
--
-- Adding the column and backfilling nothing would look like it worked and
-- leave every account with a null email — which is the exact state the
-- Edge Functions already choke on, just reached a different way. Better to
-- stop here with a readable error.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sample bytea;
  v_plain text;
begin
  select email_encrypted into v_sample
    from public.profiles
    where email_encrypted is not null
    limit 1;

  if v_sample is null then
    -- No ciphertext anywhere. Either there are no accounts yet (fine,
    -- nothing to restore) or 0021 never ran (not fine, and not something
    -- this migration can fix).
    if exists (select 1 from public.profiles) then
      raise exception
        'profiles exist but none have email_encrypted — 0021 never ran, or '
        'the ciphertext is gone. Do not continue; the addresses are not '
        'recoverable from this database.';
    end if;
    return;
  end if;

  begin
    v_plain := public.decrypt_email(v_sample);
  exception when others then
    raise exception
      'decrypt_email() failed (%), so the addresses cannot be recovered. '
      'Check the Vault secrets hops_email_encryption_key and '
      'hops_email_blind_index_key before re-running.', sqlerrm;
  end;

  if v_plain is null or position('@' in v_plain) = 0 then
    raise exception
      'decrypt_email() returned %, which is not an address. The encryption '
      'key is probably not the one these rows were written with.',
      coalesce(quote_literal(v_plain), 'null');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. The column.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists email text;

-- ---------------------------------------------------------------------------
-- 2. Backfill from the ciphertext.
--
-- Only rows that are missing it, so re-running does not churn every row.
-- ---------------------------------------------------------------------------
update public.profiles
  set email = public.decrypt_email(email_encrypted)
  where email is null
    and email_encrypted is not null;

-- ---------------------------------------------------------------------------
-- 3. Keep it filled, WITHOUT touching the nine functions 0026 rewrote.
--
-- This is the part that makes the fix hold. 0026's signup_hops_user and
-- change_hops_email set email_encrypted and email_lookup and nothing else —
-- they are live and working, and reverting them would mean re-applying
-- older definitions of nine functions and getting every one right.
--
-- So the flow is inverted instead. 0021's trigger derived the ciphertext
-- FROM the plaintext; this one derives the plaintext FROM the ciphertext.
-- Whichever writer runs, and whatever a future function forgets, email ends
-- up populated — which is exactly the "a trigger cannot be forgotten by a
-- future function" argument 0021 made for having one at all, and that
-- 0026's section 9 noted it was giving up.
--
-- BEFORE, not AFTER: it edits NEW.email in place on the row being written,
-- so there is no second UPDATE and no recursion.
-- ---------------------------------------------------------------------------
create or replace function public.sync_email_plaintext()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $fn$
begin
  if new.email_encrypted is not null then
    new.email := public.decrypt_email(new.email_encrypted);
  end if;
  return new;
end;
$fn$;

revoke all on function public.sync_email_plaintext() from public;

drop trigger if exists profiles_sync_email_plaintext on public.profiles;
create trigger profiles_sync_email_plaintext
  before insert or update of email_encrypted on public.profiles
  for each row execute function public.sync_email_plaintext();

commit;

-- ===========================================================================
-- AFTERWARDS — verify. All read-only, run them in order.
-- ===========================================================================
--
--   1. The column is back and every account has an address:
--        select count(*) as accounts,
--               count(email) as with_email,
--               count(*) filter (where email is null) as missing
--        from public.profiles;
--      Expect missing = 0.
--
--   2. The plaintext matches the ciphertext it came from:
--        select count(*) as mismatched
--        from public.profiles
--        where email_encrypted is not null
--          and email is distinct from public.decrypt_email(email_encrypted);
--      Expect 0.
--
--   3. The trigger is attached:
--        select tgname from pg_trigger
--        where tgrelid = 'public.profiles'::regclass
--          and not tgisinternal;
--      Expect profiles_sync_email_plaintext among them.
--
--   4. Then, in the app, with NO redeploy of anything:
--        - sign up a new account and confirm the 6-digit code arrives
--        - use Forgot Password and confirm that code arrives
--        - send a warning from the admin app and confirm the email arrives
--      The third is the one that proves the moderation path, which has been
--      failing for this same reason.
-- ===========================================================================
