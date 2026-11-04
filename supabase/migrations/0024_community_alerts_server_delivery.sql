-- ---------------------------------------------------------------------------
-- 0024 — Community Alerts get a server-backed delivery path.
--
-- THE PROBLEM
--
-- Community Alerts were BLE-only. An admin's alert rode chunked
-- advertisement names (CA:) for about a minute and was then gone forever.
-- Two consequences, both reported:
--
--   1. A student whose Bluetooth was off at that moment never receives the
--      alert, and never can. There is nothing to catch up with.
--   2. Even with Bluetooth on, the receiver drops any CA: message whose
--      sender tag does not resolve, via KeyDirectory, to a cached account
--      with role 'admin'. KeyDirectory syncs over the INTERNET. So a
--      student who has never been online has an empty directory and
--      silently discards every alert — Bluetooth working perfectly and
--      nothing arriving.
--
-- WHY A SERVER PATH IS THE RIGHT ANSWER HERE, AND NOT ELSEWHERE
--
-- The usual rule in this project is that peer features never touch the
-- server (see CLAUDE.md). Community Alerts is the exception that proves
-- it, because it is not a peer feature: it is admin-to-everyone,
-- read-only for students, and already depends on server state to be
-- trusted at all — the KeyDirectory lookup above IS a server dependency,
-- just an indirect and fragile one.
--
-- So this does not add a dependency; it replaces an implicit one with an
-- explicit one, and gets durability for free. The server row is also
-- authoritative about who is an admin, which removes the tag-resolution
-- guesswork entirely for alerts that arrive this way.
--
-- BLE IS NOT REPLACED. It stays the primary, instant, offline-capable
-- path — an alert still reaches everyone in range with no internet at all,
-- which is the whole point of the app. The server is the CATCH-UP path:
-- whatever a device missed, it collects next time it is online. Neither
-- alone is sufficient, which is why both exist:
--
--   Bluetooth on,  internet off  -> BLE delivers now
--   Bluetooth off, internet on   -> server delivers on next poll
--   both off                     -> delivered when either comes back
--
-- Deduplication is by (sender_username, msg_id), the same pair the BLE
-- receiver already keys reassembly on, so a message arriving by both
-- routes lands once.
-- ---------------------------------------------------------------------------

create table if not exists public.community_alerts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid references public.profiles(id) on delete set null,
  author_username text not null,
  -- The truncated tag and 6-bit id the same message went out under on BLE.
  -- Carried so a device that heard it over the radio and then fetches it
  -- from here recognises the two as one message. Nullable because an alert
  -- whose radio send failed outright still belongs in the feed.
  sender_tag text,
  msg_id smallint,
  body text not null,
  created_at timestamptz not null default (now() at time zone 'utc'),
  -- An admin deletion is a tombstone, not a row removal: receivers that
  -- already hold the message need to be told to tombstone their copy, and
  -- a deleted row would simply vanish from the fetch and leave their copy
  -- standing. Mirrors how the CX: wire deletion already behaves.
  deleted_at timestamptz,
  deleted_reason smallint,
  deleted_by uuid references public.profiles(id) on delete set null
);

alter table public.community_alerts enable row level security;
revoke all on public.community_alerts from anon, authenticated;

create index if not exists community_alerts_created_at_idx
  on public.community_alerts (created_at desc);

-- ---------------------------------------------------------------------------
-- 1. Posting — admin only.
--
-- The role check is the point: students are read-only in this feed by
-- design, and unlike the BLE path (where anyone can claim the CA: prefix
-- and the receiver has to verify it) that is enforced here rather than
-- inferred afterwards.
-- ---------------------------------------------------------------------------
create or replace function public.post_community_alert(
  p_hops_token text,
  p_body text,
  p_sender_tag text default null,
  p_msg_id int default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_admin public.profiles%rowtype;
  v_id uuid;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_body is null or length(trim(p_body)) = 0 then
    raise exception 'empty_body' using errcode = '22023';
  end if;

  insert into public.community_alerts
    (author_id, author_username, sender_tag, msg_id, body)
  values
    (v_admin.id, v_admin.username, p_sender_tag, p_msg_id, left(trim(p_body), 2000))
  returning id into v_id;

  return v_id;
end;
$fn$;

revoke all on function public.post_community_alert(text, text, text, int) from public;
grant execute on function public.post_community_alert(text, text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- 2. Fetching — any signed-in account.
--
-- Returns tombstones as well as live alerts, so a device that already
-- holds a message can learn it was withdrawn. A client that filtered
-- deleted rows out server-side would leave stale copies on every device
-- that had already received them over BLE.
--
-- p_since lets a device ask only for what it has not seen. Null fetches a
-- recent window, which is what a fresh install wants.
-- ---------------------------------------------------------------------------
create or replace function public.list_community_alerts(
  p_hops_token text,
  p_since timestamptz default null,
  p_limit int default 100
) returns table (
  id uuid,
  author_username text,
  sender_tag text,
  msg_id smallint,
  body text,
  created_at timestamptz,
  deleted_at timestamptz,
  deleted_reason smallint
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_exists boolean;
begin
  -- Any valid session may read. Deliberately not admin-gated: the whole
  -- feature is an announcement channel for every student.
  select true into v_exists from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_exists is not true then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  return query
    select c.id, c.author_username, c.sender_tag, c.msg_id, c.body,
           c.created_at, c.deleted_at, c.deleted_reason
      from public.community_alerts c
     where p_since is null or c.created_at > p_since
        -- A tombstone set after p_since must still be collected even when
        -- the alert itself predates it, or a withdrawal never propagates
        -- to a device that already had the message.
        or (c.deleted_at is not null and c.deleted_at > p_since)
     order by c.created_at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$fn$;

revoke all on function public.list_community_alerts(text, timestamptz, int) from public;
grant execute on function public.list_community_alerts(text, timestamptz, int) to anon;

-- ---------------------------------------------------------------------------
-- 3. Withdrawing — admin only, and a tombstone rather than a delete.
-- ---------------------------------------------------------------------------
create or replace function public.delete_community_alert(
  p_hops_token text,
  p_sender_tag text,
  p_msg_id int,
  p_reason int default 0
) returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_admin public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Matched on the wire identity, not the uuid, because that is what the
  -- admin app has to hand when the delete is triggered from a message
  -- bubble it received rather than one it posted.
  update public.community_alerts
     set deleted_at = (now() at time zone 'utc'),
         deleted_reason = p_reason,
         deleted_by = v_admin.id
   where sender_tag = p_sender_tag
     and msg_id = p_msg_id
     and deleted_at is null;
end;
$fn$;

revoke all on function public.delete_community_alert(text, text, int, int) from public;
grant execute on function public.delete_community_alert(text, text, int, int) to anon;
