-- Supports polling for "did my admin request just get approved?" (see
-- hops_app.dart's periodic identity-sync check). There's no push
-- notification infrastructure in this app (no FCM — it's a peer-to-peer
-- BLE mesh with only a minimal Supabase backend for identity), so a
-- remote approval can only ever be discovered by a device periodically
-- asking about itself — this is that lightweight ask. Deliberately
-- returns only role/admin_title, nothing else, keeping it as narrow as
-- signin_hops_user's existing safe-subset pattern.

create or replace function public.get_my_status(
  p_hops_token text
) returns table (role text, admin_title text)
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

  if not found then
    return;
  end if;

  return query select v_row.role, v_row.admin_title;
end;
$$;

revoke all on function public.get_my_status(text) from public;
grant execute on function public.get_my_status(text) to anon;
