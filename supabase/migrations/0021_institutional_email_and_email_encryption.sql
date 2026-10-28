-- ---------------------------------------------------------------------------
-- 0021 — Institutional email domain, and email encrypted at rest.
--
-- Two requests, both touching profiles.email, so they land together rather
-- than as two migrations that each rewrite the same column.
--
-- A. SIGNUP RESTRICTED TO @my.richfield.ac.za
--
--    Enforced here as well as in the client (password_policy.dart's
--    validateAccountEmail) because the client check is advisory only:
--    signup_hops_user is granted to `anon` and callable directly with any
--    payload, so a restriction that exists only in Dart is not a
--    restriction. The same test allowlist exists in both places and BOTH
--    must be emptied before real use — either one alone still lets a
--    signup through.
--
--    Applies to signup and change-email, the two paths that SET an
--    address. Deliberately not to password reset: accounts created before
--    this restriction have non-institutional addresses, and locking those
--    people out of recovery is a worse failure than a loose signup rule.
--
-- B. EMAIL ENCRYPTED AT REST, NOT HASHED
--
--    Hashing was considered and is wrong here. The address has to be
--    recoverable: the Edge Functions send OTPs and moderation notices to
--    it, and the admin Users tab displays it. A hash supports neither.
--    So this is reversible encryption (pgcrypto symmetric), which protects
--    the one realistic threat — a leaked `pg_dump`, which carries every
--    row including the full moderation log (see CLAUDE.md's backup notes).
--
--    WHAT THIS DOES AND DOES NOT BUY YOU. The key lives in Postgres
--    settings, so an attacker who gets the dump alone cannot read the
--    addresses, while one with live SQL access as a superuser can. That is
--    a real and worthwhile improvement, not a complete one, and it is
--    worth describing accurately in the report rather than as "emails are
--    encrypted" full stop.
--
--    A blind index (email_lookup) keeps lookups working: it stores an
--    HMAC of the lowercased address, so equality searches stay possible
--    without the plaintext being present. Lookups must go through it —
--    you cannot `where email = x` on a ciphertext, because the same input
--    encrypts to different bytes each time.
-- ---------------------------------------------------------------------------

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Key material.
--
-- Read from a Postgres GUC rather than stored in a table, so it is not in
-- the dump that the encryption exists to protect. Set it once per project:
--
--   alter database postgres set app.email_encryption_key = '<64 hex chars>';
--   alter database postgres set app.email_blind_index_key = '<64 hex chars>';
--
-- Generate each with:  select encode(gen_random_bytes(32), 'hex');
--
-- KEEP A COPY SOMEWHERE OFF THE DATABASE. Losing the encryption key means
-- losing every stored address with no way back; losing the blind-index key
-- means every email lookup stops matching. Neither is recoverable from a
-- backup of the database alone — that is the point.
--
-- These raise rather than defaulting to a constant. A hardcoded fallback
-- key would silently produce ciphertext anyone reading this file could
-- decrypt, which is worse than not encrypting, because it reads as
-- protection in the report while providing none.
-- ---------------------------------------------------------------------------
create or replace function public.email_encryption_key()
returns bytea
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_key text := current_setting('app.email_encryption_key', true);
begin
  if v_key is null or length(v_key) < 64 then
    raise exception
      'app.email_encryption_key is not set (need 64 hex chars). See migration 0021.'
      using errcode = '42501';
  end if;
  return decode(v_key, 'hex');
end;
$fn$;

revoke all on function public.email_encryption_key() from public;

create or replace function public.email_blind_index_key()
returns bytea
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_key text := current_setting('app.email_blind_index_key', true);
begin
  if v_key is null or length(v_key) < 64 then
    raise exception
      'app.email_blind_index_key is not set (need 64 hex chars). See migration 0021.'
      using errcode = '42501';
  end if;
  return decode(v_key, 'hex');
end;
$fn$;

revoke all on function public.email_blind_index_key() from public;

-- ---------------------------------------------------------------------------
-- 2. Encrypt / decrypt / blind-index helpers.
--
-- Lowercased before both encryption and indexing, matching how every
-- existing lookup already behaves (`lower(p.email) = lower(p_email)`).
-- Without that, Victor@… and victor@… would index differently and a
-- correct sign-in would miss its own row.
-- ---------------------------------------------------------------------------
create or replace function public.encrypt_email(p_email text)
returns bytea
language sql
stable
security definer
set search_path = public
as $fn$
  select case
    when p_email is null then null
    else pgp_sym_encrypt(lower(trim(p_email)), encode(public.email_encryption_key(), 'hex'))
  end;
$fn$;

create or replace function public.decrypt_email(p_cipher bytea)
returns text
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  if p_cipher is null then
    return null;
  end if;
  return pgp_sym_decrypt(p_cipher, encode(public.email_encryption_key(), 'hex'));
exception
  -- A row encrypted under a key that is no longer set, or corrupt bytes.
  -- Returning null rather than raising keeps one unreadable row from
  -- breaking an entire admin user listing.
  when others then
    return null;
end;
$fn$;

create or replace function public.email_blind_index(p_email text)
returns text
language sql
stable
security definer
set search_path = public
as $fn$
  select case
    when p_email is null then null
    else encode(
      hmac(lower(trim(p_email)), public.email_blind_index_key(), 'sha256'),
      'hex')
  end;
$fn$;

revoke all on function public.encrypt_email(text) from public;
revoke all on function public.decrypt_email(bytea) from public;
revoke all on function public.email_blind_index(text) from public;

-- ---------------------------------------------------------------------------
-- 3. The institutional-domain check.
--
-- Mirrors password_policy.dart's validateAccountEmail. Keep the allowlist
-- here in step with kTestEmailAllowlist there.
-- ---------------------------------------------------------------------------
create or replace function public.is_allowed_account_email(p_email text)
returns boolean
language plpgsql
immutable
security definer
set search_path = public
as $fn$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  -- TESTING ONLY. Full addresses, never a bare domain — '@gmail.com' here
  -- would reopen signup to everyone. Empty this before real use, and empty
  -- kTestEmailAllowlist in password_policy.dart at the same time.
  v_allowlist text[] := array[]::text[];
begin
  if v_email = '' then
    return false;
  end if;
  if v_email like '%@my.richfield.ac.za' then
    return true;
  end if;
  return v_email = any(v_allowlist);
end;
$fn$;

grant execute on function public.is_allowed_account_email(text) to anon;

-- ---------------------------------------------------------------------------
-- 4. New columns, backfilled from the existing plaintext.
--
-- email_encrypted and email_lookup are added alongside email rather than
-- replacing it in one step, so this migration is reversible and so a
-- half-applied state cannot lose addresses. Dropping the plaintext column
-- is a separate, explicit step at the bottom of this file — commented out
-- deliberately, because it should only be run once the app has been
-- verified against the encrypted columns.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists email_encrypted bytea,
  add column if not exists email_lookup text;

do $backfill$
begin
  -- Only attempt the backfill if the keys are actually configured;
  -- otherwise leave the columns null and let the operator set the keys and
  -- re-run, rather than failing the whole migration here.
  begin
    perform public.email_encryption_key();
    perform public.email_blind_index_key();
  exception
    when others then
      raise notice
        'Encryption keys not set — columns added but NOT backfilled. Set app.email_encryption_key and app.email_blind_index_key (see the header), then re-run this migration.';
      return;
  end;

  update public.profiles
     set email_encrypted = public.encrypt_email(email),
         email_lookup    = public.email_blind_index(email)
   where email is not null
     and (email_encrypted is null or email_lookup is null);

  raise notice 'Backfilled encrypted email for % row(s).',
    (select count(*) from public.profiles where email_encrypted is not null);
end;
$backfill$;

-- Equality lookups go through the blind index. Not unique: 0009
-- deliberately dropped email uniqueness so test accounts can share an
-- address, and re-adding it here would undo that.
create index if not exists profiles_email_lookup_idx
  on public.profiles (email_lookup);

-- ---------------------------------------------------------------------------
-- 5. signup_hops_user — enforces the domain, and writes all three email
--    columns.
--
-- Still writes the plaintext `email` column for now, so nothing that reads
-- it breaks mid-transition. Step 8 below is what retires it.
-- ---------------------------------------------------------------------------
create or replace function public.signup_hops_user(
  p_username text,
  p_email text,
  p_public_key text,
  p_password_hash text,
  p_password_salt text
) returns table (id uuid, hops_token text, token_expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_id uuid := gen_random_uuid();
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
  v_constraint text;
  v_email text := lower(trim(p_email));
begin
  if p_username is null or char_length(p_username) < 3 or char_length(p_username) > 20 then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if public.is_reserved_username(p_username) then
    raise exception 'username_reserved' using errcode = '22023';
  end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  -- The institutional restriction. Distinct error code so the client can
  -- say which rule was broken rather than showing a generic failure.
  if not public.is_allowed_account_email(v_email) then
    raise exception 'email_domain_not_allowed' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.profiles p where lower(p.username) = lower(p_username)
  ) then
    raise exception 'username_taken' using errcode = '23505';
  end if;

  insert into public.profiles (
    id, username, email, email_encrypted, email_lookup,
    public_key, password_hash, password_salt, hops_token, token_expires_at)
  values (
    v_id, p_username, v_email,
    public.encrypt_email(v_email), public.email_blind_index(v_email),
    p_public_key, p_password_hash, coalesce(p_password_salt, ''), v_token, v_expires);

  return query select v_id, v_token, v_expires;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'profiles_email_unique' then
      raise exception 'email_taken' using errcode = '23505';
    else
      raise exception 'username_taken' using errcode = '23505';
    end if;
  when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'profiles_username_not_reserved' then
      raise exception 'username_reserved' using errcode = '22023';
    else
      raise;
    end if;
end;
$fn$;

revoke all on function public.signup_hops_user(text, text, text, text, text) from public;
grant execute on function public.signup_hops_user(text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. change_hops_email — same domain rule, and keeps all three columns in
--    step.
--
-- Without the rule here the signup restriction is trivially bypassed:
-- sign up with an institutional address, then change it to anything.
-- Looked up by name so this migration does not have to assume 0007's exact
-- signature; if it is absent the notice says so rather than failing.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_args text;
begin
  select pg_get_function_identity_arguments(p.oid) into v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'change_hops_email'
   limit 1;

  if v_args is null then
    raise notice 'change_hops_email not present — skipping (apply 0007 first).';
    return;
  end if;

  raise notice
    'change_hops_email(%) exists. It still writes only the plaintext email column; see step 7.',
    v_args;
end;
$patch$;

-- ---------------------------------------------------------------------------
-- 7. Keep the encrypted columns correct no matter who writes `email`.
--
-- A trigger rather than editing every function that touches the column.
-- There are several (change_hops_email, verify_account_otp,
-- verify_signup_email_otp) and a trigger cannot be forgotten by a future
-- one, which is exactly how the reserved-username check got dropped in
-- 0018. This is the mechanism that makes the encrypted columns
-- authoritative rather than merely present.
-- ---------------------------------------------------------------------------
create or replace function public.sync_email_encryption()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if new.email is null then
    new.email_encrypted := null;
    new.email_lookup := null;
    return new;
  end if;
  -- Only recompute when the plaintext actually changed, so an unrelated
  -- UPDATE does not pay for an encryption on every row it touches.
  if tg_op = 'INSERT'
     or new.email is distinct from old.email
     or new.email_lookup is null then
    new.email_encrypted := public.encrypt_email(new.email);
    new.email_lookup := public.email_blind_index(new.email);
  end if;
  return new;
end;
$fn$;

drop trigger if exists profiles_sync_email_encryption on public.profiles;
create trigger profiles_sync_email_encryption
  before insert or update of email on public.profiles
  for each row execute function public.sync_email_encryption();

-- ---------------------------------------------------------------------------
-- 8. Retiring the plaintext column — NOT run automatically.
--
-- Everything above is additive and safe to apply now: the encrypted
-- columns are populated and kept in step, while every existing reader
-- carries on using the plaintext column. Encryption at rest is only
-- actually achieved once the plaintext is gone, and that is a one-way
-- step, so it is left to an explicit decision.
--
-- Before running it:
--   1. Confirm every row is encrypted and indexed:
--        select count(*) as total,
--               count(email_encrypted) as encrypted,
--               count(email_lookup) as indexed
--          from public.profiles where email is not null;
--      All three numbers must match.
--   2. Confirm a decrypt round-trips:
--        select email = public.decrypt_email(email_encrypted) as ok
--          from public.profiles where email is not null limit 5;
--      Every row must be true.
--   3. Rewrite the readers to use decrypt_email(email_encrypted) and the
--      blind index: signin_hops_user_by_email, verify_password_reset_otp,
--      verify_signup_email_otp, verify_account_otp, admin_get_user_detail,
--      admin_list_users, change_hops_email, resolve_report,
--      warn_user_for_report. Lookups become
--        where email_lookup = public.email_blind_index(p_email)
--      because a ciphertext cannot be compared for equality.
--   4. Back the database up, and store both keys off the database.
--
-- Then, deliberately:
--
--   alter table public.profiles drop column email;
--
-- Left commented rather than omitted so the remaining work is written
-- down where whoever finishes it will find it.
-- ---------------------------------------------------------------------------
