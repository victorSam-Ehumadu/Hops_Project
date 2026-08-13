-- Supports the Admin Official Alert tier (ADM:/ADM_OFF:), which needs two
-- things the earlier migrations didn't expose:
--   1. A device verifying an Official Alert must be able to tell, fully
--      offline, whether the signer is actually an admin — not just that
--      the signature is valid. role/admin_title are no more sensitive than
--      username/public_key already exposed here (knowing someone's role is
--      the whole point of this feature), so extending the same safe view
--      is correct rather than adding a second one.
--   2. The client itself needs to know its own current role at sign-in to
--      decide whether to show the Official Alert trigger UI at all.

-- Additive column list on an existing view — CREATE OR REPLACE VIEW keeps
-- the view's existing grants as long as no existing column is removed or
-- reordered, only appended to.
create or replace view public.profiles_public as
  select id, username, public_key, role, admin_title
  from public.profiles;

-- signin_hops_user's RETURN TABLE shape is changing (two new columns),
-- which CREATE OR REPLACE FUNCTION cannot do — Postgres requires DROP +
-- CREATE for that, not just a body swap.
drop function if exists public.signin_hops_user(text, text);

create or replace function public.signin_hops_user(
  p_username text,
  p_password_hash text
) returns table (
  id uuid,
  username text,
  public_key text,
  hops_token text,
  token_expires_at timestamptz,
  role text,
  admin_title text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
begin
  select * into v_row from public.profiles p where p.username = p_username;

  if not found or v_row.password_hash is distinct from p_password_hash then
    return; -- empty result set — client treats as invalid credentials
  end if;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where id = v_row.id;

  return query
    select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
           v_row.role, v_row.admin_title;
end;
$$;

revoke all on function public.signin_hops_user(text, text) from public;
grant execute on function public.signin_hops_user(text, text) to anon;
