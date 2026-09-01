-- Backs the new "Account Management" screen (client/lib/views/
-- account_management_screen.dart): change password, and delete account.
-- ("Log Out" is purely local — clears SharedPreferences/secure storage —
-- so it needs no server-side support.)
--
-- Both functions follow the same shape as signin_hops_user/get_my_status:
-- SECURITY DEFINER, take the caller's hops_token, verify it's live
-- (matches AND not expired) before doing anything, and never distinguish
-- "wrong token" from "wrong password" in what's returned — same
-- enumeration-resistance reasoning as sign-in.

-- ---------------------------------------------------------------------------
-- 1. Change password. Verifies the CURRENT password hash server-side
--    before overwriting it — the client never gets to just declare a new
--    password without proving it knows the old one. Returns true on
--    success; false (not an exception) for "token or old password didn't
--    check out", so the client can show one generic message either way.
-- ---------------------------------------------------------------------------
create or replace function public.change_hops_password(
  p_hops_token text,
  p_old_password_hash text,
  p_new_password_hash text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_old_password_hash then
    return false;
  end if;

  update public.profiles
    set password_hash = p_new_password_hash
    where id = v_row.id;

  return true;
end;
$$;

revoke all on function public.change_hops_password(text, text, text) from public;
grant execute on function public.change_hops_password(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Delete account. Same verify-then-act shape — requires the current
--    password, not just a live token, since this is destructive and a
--    stolen/leaked token alone (e.g. an unlocked phone) shouldn't be
--    enough on its own to nuke the account.
-- ---------------------------------------------------------------------------
create or replace function public.delete_hops_user(
  p_hops_token text,
  p_password_hash text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_password_hash then
    return false;
  end if;

  delete from public.profiles where id = v_row.id;

  return true;
end;
$$;

revoke all on function public.delete_hops_user(text, text) from public;
grant execute on function public.delete_hops_user(text, text) to anon;
