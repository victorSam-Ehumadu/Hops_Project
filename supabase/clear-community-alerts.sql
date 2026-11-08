-- Wipe the Community Alerts feed held on the server.
--
-- WHERE TO RUN
--
--   Supabase dashboard -> your project -> SQL Editor -> New query.
--   Run QUERY 1 first to see what you are about to delete, then QUERY 2.
--   The editor shows only the LAST result when several statements run
--   together, so select one query at a time and press Run.
--
-- WHAT THIS DOES AND DOES NOT DO
--
-- Community Alerts live in TWO places, and this clears one of them.
--
--   1. public.community_alerts on the server (0024). That is this file.
--      Clearing it stops the 30-second catch-up poll in
--      services/community_alert_sync.dart handing the same messages back
--      out to every device that asks.
--
--   2. A copy on EVERY device that ever received them, in SharedPreferences
--      under 'community_alerts_v1'. Nothing in SQL can reach that. Each
--      phone clears its own from the Community Alerts screen: the broom
--      icon in the app bar, "Clear this feed".
--
-- So the order matters. Clear the SERVER first, then each phone — the
-- other way round and the next poll pulls everything straight back.
--
-- THIS IS NOT THE SAME AS AN ADMIN DELETION. Removing one message as an
-- admin (long-press it in the app) broadcasts CX: so every device in range
-- tombstones it, and records who removed it and why. That is the right
-- tool for one bad message and leaves an audit trail. This file is the
-- blunt instrument for clearing out test traffic, and it leaves nothing
-- behind: no tombstones, no log entry, no way to tell what was here.
--
-- IRREVERSIBLE. There is no soft-delete column on this table and no
-- backup of it other than whatever pg_dump you last took
-- (scripts/backup-db.ps1). Run QUERY 1 first.

-- ===========================================================================
-- QUERY 1 OF 2 — WHAT IS THERE NOW.  Select this block and Run.
-- ===========================================================================
select
  count(*)                      as alerts_total,
  count(*) filter (where deleted_at is not null) as already_deleted,
  min(created_at)               as oldest,
  max(created_at)               as newest,
  count(distinct author_username) as distinct_authors
from public.community_alerts;

-- ===========================================================================
-- QUERY 2 OF 2 — DELETE THEM ALL.  Select from "delete" to the semicolon.
--
-- To keep anything, add a WHERE clause before running. Useful shapes:
--
--   delete from public.community_alerts
--     where created_at < now() - interval '1 day';   -- only older than a day
--
--   delete from public.community_alerts
--     where author_username = 'Victor';              -- only one author's
--
-- The bare form below removes every alert.
-- ===========================================================================
delete from public.community_alerts;

-- Confirm it is empty. Should return 0.
select count(*) as alerts_remaining from public.community_alerts;
