-- 0026 — Retire the plaintext profiles.email column.
--
-- 0021 added email_encrypted and email_lookup and kept the plaintext column
-- alongside them, deliberately: everything in 0021 is additive and safe to
-- apply at any time, but encryption at rest is only actually ACHIEVED once
-- the plaintext is gone. This migration finishes that job.
--
-- ===========================================================================
-- READ THIS BEFORE RUNNING IT. THIS MIGRATION IS NOT REVERSIBLE.
-- ===========================================================================
--
-- Dropping the column destroys the only readable copy of every user's email
-- address. From then on the ONLY way to read an email is to decrypt it with
-- the Vault key `hops_email_encryption_key`, and the only way to look one up
-- is the HMAC key `hops_email_blind_index_key`.
--
-- If either key is lost after this runs, the consequence is not "emails look
-- scrambled". It is:
--
--   * nobody can sign in by email address, ever again;
--   * nobody can reset a forgotten password;
--   * the admin app shows a blank email for every account;
--
-- and there is no recovery path, because the plaintext the keys protect is
-- the thing that was deleted. A database restore only helps if the backup
-- predates this migration.
--
-- PREREQUISITES — all four, in order. Do not skip 2.
--
--   1. Both Vault secrets exist (0021 created them):
--
--        select name from vault.decrypted_secrets
--        where name like 'hops_email_%';
--
--      Two rows expected: hops_email_encryption_key and
--      hops_email_blind_index_key.
--
--   2. BOTH KEY VALUES ARE STORED SOMEWHERE OUTSIDE THIS DATABASE — a
--      password manager, not a file in the repo, and not only in Vault.
--      Vault lives in the database; a lost project takes the keys with it.
--      This is the step that makes the difference between "encrypted" and
--      "permanently unreadable", and it is currently UNTICKED on
--      docs/action-checklist.md.
--
--   3. Every row is encrypted and indexed, and a decrypt round-trips:
--
--        select count(*) as total,
--               count(email_encrypted) as encrypted,
--               count(email_lookup) as indexed
--          from public.profiles where email is not null;
--        -- all three numbers must be equal
--
--        select bool_and(email = public.decrypt_email(email_encrypted)) as ok
--          from public.profiles where email is not null;
--        -- must return true
--
--      If `ok` is false or null, STOP. A row whose ciphertext does not match
--      its plaintext was encrypted under a different key, and dropping the
--      column loses that address.
--
--   4. Take a fresh backup:
--        powershell -ExecutionPolicy Bypass -File .\scripts\backup-db.ps1
--
-- TIMING. Do not apply this in the days before a demonstration or
-- assessment. It rewrites the whole sign-in, password-reset and admin-user
-- path at once, and if something is wrong the symptom is "nobody can log
-- in". There is no user-visible benefit to rushing it — the encrypted
-- columns are already populated and already correct.
--
-- REHEARSE IT FIRST, on a copy. This is the whole reason verify-backup.ps1
-- grew a -Keep switch, and it costs nothing:
--
--   powershell -ExecutionPolicy Bypass -File .\scripts\verify-backup.ps1 -Keep
--   psql -U postgres -d hops_restore_test -f supabase\migrations\0026_retire_plaintext_email.sql
--
-- The restored copy has no Vault, so encrypt_email/decrypt_email cannot
-- actually run there — what this proves is narrower than a full test, but
-- it is exactly the half that bites: that all eight functions CREATE
-- without a syntax or signature error, that the trigger drops, and that
-- `drop column ... restrict` finds no dependent object this migration
-- missed. If the transaction commits on the copy, the shape is right.
--
-- Afterwards: dropdb hops_restore_test
-- That scratch database holds every row of the cloud database, password
-- hashes and the full moderation log included. Do not leave it lying about.
--
-- ===========================================================================
-- WHAT THIS CHANGES, AND WHY THE LIST DIFFERS FROM 0021's
-- ===========================================================================
--
-- 0021 section 8 listed the readers to rewrite. That list was wrong in both
-- directions, which is worth recording because following it would have
-- broken sign-in:
--
--   MISSED by 0021, and required:
--     * get_password_salt_by_email  — the PRE-authentication salt lookup.
--       Every email sign-in calls this first. Had the column been dropped
--       without fixing it, the salt lookup would fail, the client would hash
--       against a fallback salt, and EVERY email sign-in would be rejected
--       as a wrong password.
--     * admin_search_users          — 0021 called it `admin_list_users`,
--       which does not exist in this schema.
--     * admin_list_flagged_reporters
--     * signup_hops_user            — a WRITER, not a reader.
--     * sync_email_encryption       — the trigger whose whole job is copying
--       plaintext into the encrypted columns. With no plaintext it has
--       nothing to read, so it must go and the writers must set the
--       encrypted columns themselves.
--
--   LISTED by 0021 but NOT affected (they never read profiles.email):
--     verify_signup_email_otp, verify_account_otp, resolve_report,
--     warn_user_for_report. verify_signup_email_otp only WRITES
--     email_verified; the OTP tables keep their own separate email columns,
--     which this migration does not touch.
--
-- Checked by scanning the latest definition of every function in
-- supabase/migrations for a reference to the bare `email` column, rather
-- than by trusting the note.
--
-- NOT DONE HERE: no unique index on email_lookup. 0009 deliberately dropped
-- profiles_email_unique so that a handful of test addresses could be shared
-- across more accounts than there are addresses. Adding uniqueness on the
-- blind index would silently re-impose the constraint 0009 removed and break
-- that setup. When 0009 is reverted, the equivalent is:
--
--   create unique index profiles_email_lookup_unique
--     on public.profiles (email_lookup) where email_lookup is not null;
--
-- and signup_hops_user's exception handler below should then test for
-- 'profiles_email_lookup_unique'.
--
-- STILL NOT ACHIEVED, so nobody claims otherwise: the OTP tables
-- (password_reset_otps, email_verification_otps) hold plaintext email
-- addresses of their own. They are short-lived rows, but they are plaintext,
-- and "emails are encrypted at rest" is only true of profiles until those
-- are dealt with too.
--
-- The whole file runs in one transaction: if any function fails to create,
-- the column is NOT dropped and nothing has changed.

begin;

-- ---------------------------------------------------------------------------
-- 1. The pre-authentication salt lookup.
--
-- The one 0021 missed, and the one that would have broken every email
-- sign-in. Keeps `extensions` on the search_path for digest() in the
-- no-such-account fallback.
-- ---------------------------------------------------------------------------
create or replace function public.get_password_salt_by_email(
  p_email text
) returns text
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_salt text;
begin
  -- Blind index, not the ciphertext: the same address encrypts to a
  -- different value every time, so `where email_encrypted = ...` can never
  -- match. The HMAC is deterministic, which is the entire point of it.
  select password_salt into v_salt
    from public.profiles
    where email_lookup = public.email_blind_index(p_email);

  if v_salt is not null then
    return v_salt;
  end if;

  -- Deterministic per address, so repeated probes of the same unknown
  -- email return a consistent value exactly as a real account would.
  return encode(digest('hops-no-such-account:' || lower(p_email), 'sha256'), 'hex');
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Sign in by email.
-- ---------------------------------------------------------------------------
create or replace function public.signin_hops_user_by_email(
  p_email text,
  p_password_hash text
) returns table (
  id uuid, username text, public_key text, hops_token text,
  token_expires_at timestamptz, role text, admin_title text, email_verified boolean
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_row public.profiles%rowtype;
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz;
begin
  -- Matches email AND password together — see 0009: with duplicate emails
  -- allowed for testing, this is what picks the right account instead of
  -- an arbitrary one sharing the address.
  select * into v_row
    from public.profiles p
    where p.email_lookup = public.email_blind_index(p_email)
      and p.password_hash = p_password_hash;

  if not found then
    return; -- empty result set — client treats as invalid credentials
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  if v_row.suspended_until is not null and v_row.suspended_until > (now() at time zone 'utc') then
    raise exception 'account_suspended'
      using errcode = '28000',
            detail = to_char(v_row.suspended_until, 'YYYY-MM-DD') ||
                     coalesce(' — ' || v_row.suspension_reason, '');
  end if;

  v_expires := (now() at time zone 'utc')
    + case when v_row.role = 'admin' then interval '90 days' else interval '24 hours' end;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
    v_row.role, v_row.admin_title, v_row.email_verified;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Password reset.
--
-- Only the profiles lookup changes. The first query reads
-- password_reset_otps, which keeps its own plaintext email column and is
-- NOT touched here — see the header note.
-- ---------------------------------------------------------------------------
create or replace function public.verify_password_reset_otp(
  p_email text,
  p_otp_hash text,
  p_new_password_hash text,
  p_new_password_salt text
) returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_otp public.password_reset_otps%rowtype;
  v_profile_id uuid;
begin
  select * into v_otp
    from public.password_reset_otps
    where lower(email) = lower(p_email)
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.password_reset_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  select id into v_profile_id
    from public.profiles
    where email_lookup = public.email_blind_index(p_email);
  if v_profile_id is null then
    return false;
  end if;

  update public.password_reset_otps set used = true where id = v_otp.id;
  update public.profiles
    set password_hash = p_new_password_hash,
        password_salt = coalesce(p_new_password_salt, '')
    where id = v_profile_id;

  return true;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Change email address.
--
-- A WRITER. With the trigger gone it sets both encrypted columns itself.
-- ---------------------------------------------------------------------------
create or replace function public.change_hops_email(
  p_hops_token text,
  p_password_hash text,
  p_new_email text
) returns boolean
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_row public.profiles%rowtype;
  v_email text := lower(trim(coalesce(p_new_email, '')));
begin
  if v_email = '' or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_password_hash then
    return false;
  end if;

  begin
    update public.profiles
      set email_encrypted = public.encrypt_email(v_email),
          email_lookup = public.email_blind_index(v_email),
          email_verified = false
      where id = v_row.id;
  exception
    when unique_violation then
      raise exception 'email_taken' using errcode = '23505';
  end;

  return true;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Sign up.
--
-- A WRITER. Drops `email` from the INSERT column list; the encrypted
-- columns were already being set explicitly by 0021, so the trigger was
-- belt-and-braces here rather than the mechanism.
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
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if p_username is null or char_length(p_username) < 3 or char_length(p_username) > 20 then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if public.is_reserved_username(p_username) then
    raise exception 'username_reserved' using errcode = '22023';
  end if;
  if v_email = '' or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
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
    id, username, email_encrypted, email_lookup,
    public_key, password_hash, password_salt, hops_token, token_expires_at)
  values (
    v_id, p_username,
    public.encrypt_email(v_email), public.email_blind_index(v_email),
    p_public_key, p_password_hash, coalesce(p_password_salt, ''), v_token, v_expires);

  return query select v_id, v_token, v_expires;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    -- profiles_email_unique was dropped by 0009 and its blind-index
    -- equivalent is not created by this migration, so the email branch is
    -- currently unreachable. Both names are tested so that reverting 0009
    -- needs no change here.
    if v_constraint in ('profiles_email_unique', 'profiles_email_lookup_unique') then
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

-- ---------------------------------------------------------------------------
-- 6. Admin: search users.
--
-- Two changes. The returned email is decrypted, and the search predicate
-- decrypts before matching, because `ilike` against a ciphertext matches
-- nothing — a partial-email search would have silently stopped finding
-- anyone rather than failing loudly.
--
-- Cost: this decrypts every row to evaluate the filter, so it is a full
-- scan with a per-row decrypt. Accepted deliberately — this table holds
-- campus accounts, the result is capped at 200, and it only runs when an
-- admin types in the search box. An exact-address lookup should use
-- email_lookup = public.email_blind_index(...) instead, which is indexed.
-- ---------------------------------------------------------------------------
create or replace function public.admin_search_users(
  p_hops_token text,
  p_query text default null,
  p_limit int default 50
) returns table (
  id uuid, username text, email text, role text, admin_title text,
  banned boolean, ban_reason text, email_verified boolean
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select p.id, p.username, public.decrypt_email(p.email_encrypted),
           p.role, p.admin_title, p.banned, p.ban_reason, p.email_verified
    from public.profiles p
    where p_query is null or p_query = ''
      or p.username ilike '%' || p_query || '%'
      or public.decrypt_email(p.email_encrypted) ilike '%' || p_query || '%'
    order by p.username asc
    limit least(coalesce(p_limit, 50), 200);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Admin: one user's detail.
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_user_detail(
  p_hops_token text,
  p_target_id uuid
) returns table (
  id uuid,
  username text,
  email text,
  role text,
  admin_title text,
  created_at timestamptz,
  email_verified boolean,
  banned boolean,
  ban_reason text,
  banned_at timestamptz,
  suspended_until timestamptz,
  suspension_reason text,
  ban_count bigint,
  suspend_count bigint,
  warning_count bigint,
  reports_against bigint,
  reports_actioned_against bigint,
  reports_filed bigint,
  dismissed_reports_count integer,
  reporter_warned_at timestamptz,
  reporter_flagged_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_admin public.profiles%rowtype;
  v_t public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_t from public.profiles where public.profiles.id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  return query select
    v_t.id, v_t.username, public.decrypt_email(v_t.email_encrypted),
    v_t.role, v_t.admin_title, v_t.created_at,
    coalesce(v_t.email_verified, false),
    v_t.banned, v_t.ban_reason, v_t.banned_at,
    v_t.suspended_until, v_t.suspension_reason,
    -- target_id is only populated from 0015 onward, so older rows are
    -- matched on username too. Both sides are needed: username catches
    -- history, target_id survives a rename.
    (select count(*) from public.admin_actions_log l
      where l.action = 'ban' and (l.target_id = v_t.id or l.target_username = v_t.username)),
    (select count(*) from public.admin_actions_log l
      where l.action = 'suspend' and (l.target_id = v_t.id or l.target_username = v_t.username)),
    (select count(*) from public.user_notifications n
      where n.recipient_id = v_t.id and n.type = 'warning'),
    (select count(*) from public.content_reports r where r.target_username = v_t.username),
    (select count(*) from public.content_reports r
      where r.target_username = v_t.username and r.status = 'actioned'),
    (select count(*) from public.content_reports r where r.reporter_id = v_t.id),
    v_t.dismissed_reports_count, v_t.reporter_warned_at, v_t.reporter_flagged_at;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. Admin: flagged reporters.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_flagged_reporters(
  p_hops_token text
) returns table (
  id uuid,
  username text,
  email text,
  dismissed_reports_count integer,
  reports_filed bigint,
  reporter_flagged_at timestamptz,
  banned boolean,
  suspended_until timestamptz
)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_admin public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select p.id, p.username, public.decrypt_email(p.email_encrypted),
           p.dismissed_reports_count,
           (select count(*) from public.content_reports r where r.reporter_id = p.id),
           p.reporter_flagged_at, p.banned, p.suspended_until
      from public.profiles p
      where p.reporter_flagged_at is not null
      order by p.reporter_flagged_at asc;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 9. Retire the sync trigger.
--
-- Its entire job was copying plaintext into the encrypted columns. With no
-- plaintext column there is nothing to copy FROM, and leaving it attached
-- would fail on every insert (`new.email` would not resolve). The writers
-- above now set both encrypted columns explicitly.
--
-- The trade 0021 made by using a trigger — "a trigger cannot be forgotten
-- by a future function, which is how the reserved-username check got
-- dropped in 0018" — is real, and it is lost here. Any NEW function that
-- writes an email address must remember to set email_encrypted AND
-- email_lookup itself. There are two such functions today, both above.
-- ---------------------------------------------------------------------------
drop trigger if exists profiles_sync_email_encryption on public.profiles;
drop function if exists public.sync_email_encryption();

-- ---------------------------------------------------------------------------
-- 10. The irreversible bit.
--
-- `restrict` rather than `cascade`, on purpose: if anything still depends
-- on this column — a view, an index, a constraint, a function with a
-- declared dependency — this FAILS and rolls the whole transaction back,
-- instead of quietly dropping that dependent object too. A migration that
-- silently deletes a view is worse than one that stops.
--
-- If this line errors with "cannot drop ... because other objects depend on
-- it", read the detail: it is telling you about a reader this migration did
-- not know about. Fix that reader, then re-run. Do not change this to
-- cascade.
-- ---------------------------------------------------------------------------
alter table public.profiles drop column email restrict;

commit;

-- ===========================================================================
-- AFTERWARDS — verify, in this order. All read-only.
-- ===========================================================================
--
--   1. The column is gone and the encrypted pair survived:
--        select column_name from information_schema.columns
--        where table_name = 'profiles' and column_name like '%email%'
--        order by column_name;
--      Expect: email_encrypted, email_lookup, email_verified.
--      Expect NOT: email.
--
--   2. Decryption still works for every row:
--        select count(*) as rows,
--               count(public.decrypt_email(email_encrypted)) as readable
--          from public.profiles where email_encrypted is not null;
--      The two numbers must match. A shortfall means those rows were
--      encrypted under a key that is no longer set.
--
--   3. The blind-index lookup finds a real account. Use an address you
--      know exists:
--        select username from public.profiles
--        where email_lookup = public.email_blind_index('<a real address>');
--      One row expected. If this returns nothing, sign-in by email is
--      broken — the two keys are the first thing to check.
--
--   4. The trigger is gone:
--        select tgname from pg_trigger
--        where tgrelid = 'public.profiles'::regclass and not tgisinternal;
--      profiles_sync_email_encryption must not appear.
--
--   5. Then exercise the real paths on a device, in this order, because
--      each one is a different function above: sign in by email; forgot
--      password end to end; change email; sign up a new account; open the
--      admin app and search for a user by partial email.
