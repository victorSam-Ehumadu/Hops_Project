-- Fixes a latent bug found while locking down profiles: root_gatekeeper.dart's
-- sign-in flow regenerates a fresh RSA keypair locally when private_key is
-- missing from secure storage (reinstall, new device), but had no way to
-- push the new public_key to Supabase — the direct UPDATE that would have
-- done it is exactly what 0001_lockdown_profiles.sql revoked. Left
-- unfixed, the server-side directory silently drifts out of sync with what
-- the device actually holds, which would break Emergency Flare signature
-- verification for that user from then on.

create or replace function public.refresh_public_key(
  p_hops_token text,
  p_public_key text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid;
begin
  select p.id into v_caller_id
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_caller_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  update public.profiles set public_key = p_public_key where id = v_caller_id;
end;
$$;

revoke all on function public.refresh_public_key(text, text) from public;
grant execute on function public.refresh_public_key(text, text) to anon;
