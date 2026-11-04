-- ---------------------------------------------------------------------------
-- 0020 — Two moderation/identity holes found during testing.
--
-- A. TWO ACCOUNTS COULD SHARE A USERNAME.
--
--    public.profiles was created in the Supabase dashboard, not by a
--    migration (grep: there is no `create table ... profiles` anywhere in
--    this directory), so which constraints it actually carries was never
--    under version control. signup_hops_user has always *assumed* a unique
--    index on username — it has no explicit duplicate check at all, it
--    just catches unique_violation from the INSERT and translates that to
--    'username_taken'. With no such index in the database, no violation is
--    ever raised and the duplicate is created silently.
--
--    Even with a plain unique constraint, 'Victor' and 'victor' would both
--    be accepted. That matters more here than in a typical app: the BLE
--    wire format truncates sender tags to 8-9 characters (see
--    hops_constants.dart), usernames address chat pings and emergency
--    stand-downs, and reserved bot usernames are compared case-folded. Two
--    case variants of one name are indistinguishable to most of the
--    protocol. So the index is on lower(username).
--
-- B. A SUSPENDED USER COULD JUST SIGN IN AGAIN.
--
--    suspended_until arrived in 0015, which taught get_my_status about it
--    but not the two sign-in functions. signin_hops_user was last defined
--    in 0008 and signin_hops_user_by_email in 0009 — both predate the
--    column and check only `banned`. So suspension was enforced solely by
--    the client's 30-second get_my_status poll: a suspended user who
--    signed out and back in, or force-closed and reopened, was let
--    straight back in, and an offline device was never stopped at all.
--
--    Ban had this same sign-in hole closed in 0008, and additionally
--    expires the token. Suspension deliberately does NOT expire the token
--    (see 0015's header: it lifts on its own, and a dead token would leave
--    the account looking permanently signed out long afterwards) — which
--    is exactly why the sign-in path has to carry the check instead.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Refuse to proceed if duplicates already exist.
--
-- `create unique index` against a column that already holds duplicates
-- fails with a message naming one arbitrary key and nothing else, which is
-- a poor thing to hand someone mid-deploy. This names every collision up
-- front. Resolving them is a judgement call — which account is the real
-- one? — so it is deliberately NOT automated. No migration here deletes a
-- user account.
-- ---------------------------------------------------------------------------
do $guard$
declare
  v_dupes text;
begin
  select string_agg(format('%s (x%s)', lower_name, n), ', ' order by lower_name)
    into v_dupes
    from (
      select lower(username) as lower_name, count(*) as n
        from public.profiles
       where username is not null
       group by lower(username)
      having count(*) > 1
    ) d;

  if v_dupes is not null then
    raise exception
      'Cannot add the username uniqueness index: these usernames are already duplicated case-insensitively: %. Consolidate or delete the extra accounts, then re-run this migration. To list the rows: select id, username, email from public.profiles where lower(username) in (select lower(username) from public.profiles group by lower(username) having count(*) > 1) order by lower(username);',
      v_dupes
      using errcode = '23505';
  end if;
end;
$guard$;

-- ---------------------------------------------------------------------------
-- 2. The index itself.
--
-- Named explicitly so signup_hops_user's exception handler can tell a
-- username collision from an email one by constraint name, rather than by
-- assuming "anything that isn't the email index must be username" — which
-- is what it does today, and which would misreport any unique index added
-- later.
-- ---------------------------------------------------------------------------
create unique index if not exists profiles_username_unique_ci
  on public.profiles (lower(username));

-- ---------------------------------------------------------------------------
-- 3. signup_hops_user — restores the reserved-name check, adds an explicit
--    duplicate check.
--
-- Two separate defects fixed here:
--
--   * 0014 added `if public.is_reserved_username(...) then raise
--     'username_reserved'`. 0018 needed a new signature for the password
--     salt, so it DROPped and re-CREATEd this function — and did not carry
--     that check across. The table constraint profiles_username_not_reserved
--     still catches it, but as a raw check_violation this function does not
--     handle, so the client renders a generic failure instead of "that name
--     is reserved". Reserving them matters because the offline assistant's
--     chat history is keyed by peer username in the local messages table
--     (see hops_engine.dart), so a real account named `Hops` would
--     interleave with the bot's own thread.
--
--   * The duplicate check is now explicit rather than relying entirely on
--     the INSERT raising. The index above is the real guarantee and the
--     handler below is still the race backstop, but an explicit check is
--     what makes the failure deterministic if this function is ever
--     deployed against a database whose index is missing — which is
--     precisely the situation that produced the bug.
--
-- CREATE OR REPLACE: the signature is unchanged from 0018, so replacing in
-- place keeps the existing GRANT. A DROP would take the grant with it and
-- lock every new signup out behind a permissions error — see 0014's note.
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
begin
  if p_username is null or char_length(p_username) < 3 or char_length(p_username) > 20 then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if public.is_reserved_username(p_username) then
    raise exception 'username_reserved' using errcode = '22023';
  end if;
  if p_email is null or p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  -- Case-insensitive, matching the index. Raises the same error the
  -- handler below does, so the client needs no new branch for it.
  if exists (
    select 1 from public.profiles p where lower(p.username) = lower(p_username)
  ) then
    raise exception 'username_taken' using errcode = '23505';
  end if;

  insert into public.profiles (id, username, email, public_key, password_hash, password_salt, hops_token, token_expires_at)
  values (v_id, p_username, lower(p_email), p_public_key, p_password_hash, coalesce(p_password_salt, ''), v_token, v_expires);

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
-- 4. Both sign-in paths now reject a suspended account.
--
-- Ordering matters, and it is the same lesson 0010/0015 already recorded
-- for get_my_status: look the row up first, then decide. The credential
-- check stays ahead of the standing checks so neither ban nor suspension
-- state leaks to someone who does not hold the password.
--
-- errcode 28000 (invalid_authorization_specification) to match the
-- account_banned raise sitting next to it. get_my_status uses 42501 for
-- the same two conditions, so the client matches on the message rather
-- than the code. DETAIL carries the expiry date and reason formatted
-- exactly as get_my_status formats it, so the client has one parser for
-- both paths.
--
-- CREATE OR REPLACE for both — signatures unchanged, grants preserved.
-- ---------------------------------------------------------------------------
create or replace function public.signin_hops_user(
  p_username text,
  p_password_hash text
) returns table (
  id uuid, username text, public_key text, hops_token text,
  token_expires_at timestamptz, role text, admin_title text
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
  select * into v_row from public.profiles p where p.username = p_username;

  if not found or v_row.password_hash is distinct from p_password_hash then
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

  -- profiles.id qualified deliberately — see 0008's note: the RETURNS
  -- TABLE column named "id" is in scope as a variable, so a bare
  -- `where id = v_row.id` is error 42702, not a warning.
  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query
    select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
           v_row.role, v_row.admin_title;
end;
$fn$;

revoke all on function public.signin_hops_user(text, text) from public;
grant execute on function public.signin_hops_user(text, text) to anon;

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
    where lower(p.email) = lower(p_email)
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

revoke all on function public.signin_hops_user_by_email(text, text) from public;
grant execute on function public.signin_hops_user_by_email(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Validate the reserved-username constraint 0014 added NOT VALID.
--
-- NOT VALID means it has only ever been applied to new rows. Validating it
-- now confirms no existing row holds a reserved name; if one does, this
-- raises and that account needs renaming — worth knowing either way.
-- ---------------------------------------------------------------------------
do $validate$
begin
  alter table public.profiles validate constraint profiles_username_not_reserved;
exception
  when undefined_object then
    null; -- constraint absent (0014 not applied) — nothing to validate
end;
$validate$;
