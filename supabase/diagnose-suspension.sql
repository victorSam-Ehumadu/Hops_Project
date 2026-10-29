-- Why is a suspension not kicking the user out?
--
-- Read-only. Supabase SQL Editor. Replace 'PUT_USERNAME_HERE' in BOTH
-- queries with the suspended account's username, then run them ONE AT A
-- TIME (the editor shows only the last result set).
--
-- These two together tell you which side the fault is on, which is the
-- thing worth knowing before changing anything: the client polls
-- get_my_status every 30 seconds and acts on the exception it raises, so
-- if the server is not raising, no amount of client work will help — and
-- if it IS raising, the fault is on the device.

-- ===========================================================================
-- QUERY 1 — IS THE SERVER STATE AND CODE RIGHT?
-- ===========================================================================
select
  p.username,
  p.banned,
  p.suspended_until,
  (now() at time zone 'utc')                      as server_utc_now,
  p.suspended_until > (now() at time zone 'utc')  as should_be_blocked,
  -- Does the deployed function actually contain the check? 0015 added it;
  -- this confirms nothing later replaced the function without it.
  (select bool_or(pr.prosrc like '%account_suspended%')
     from pg_proc pr join pg_namespace n on n.oid = pr.pronamespace
    where n.nspname = 'public' and pr.proname = 'get_my_status')
                                                  as get_my_status_checks_suspension,
  -- And the sign-in path, which is what stops them simply logging back in
  -- (0020). Separate from the above: either can be missing alone.
  (select bool_and(pr.prosrc like '%account_suspended%')
     from pg_proc pr join pg_namespace n on n.oid = pr.pronamespace
    where n.nspname = 'public'
      and pr.proname in ('signin_hops_user', 'signin_hops_user_by_email'))
                                                  as signin_blocks_suspension,
  -- A token that is already expired makes get_my_status return an empty
  -- result instead of raising, which the client correctly treats as "no
  -- verdict" rather than a suspension.
  p.token_expires_at,
  p.token_expires_at > (now() at time zone 'utc')  as token_still_valid
from public.profiles p
where lower(p.username) = lower('PUT_USERNAME_HERE');

-- ===========================================================================
-- QUERY 2 — THE DECISIVE ONE.  Calls get_my_status exactly as the app does.
-- ===========================================================================
--
-- Expected when the server side is correct:
--   ERROR: account_suspended    (SQLSTATE 42501)
--
-- If it instead RETURNS A ROW, the server is not enforcing and the client
-- can never find out. If it returns NO rows, the token has expired, which
-- is a different state and not a verdict.
--
-- Safe: get_my_status is read-only apart from nothing. It issues no writes.
select * from public.get_my_status(
  (select p.hops_token from public.profiles p
    where lower(p.username) = lower('PUT_USERNAME_HERE'))
);
