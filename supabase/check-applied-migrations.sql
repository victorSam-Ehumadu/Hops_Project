-- Which migrations in supabase/migrations/ are actually applied?
--
-- Read-only. Paste the whole file into the Supabase SQL editor and run it.
-- Nothing here writes, locks, or drops anything, so it is safe to run
-- against the live project at any time.
--
-- WHY THIS EXISTS
--
-- These migrations are applied by hand in the SQL editor, so there is no
-- schema_migrations table recording what went in. That has already cost
-- real debugging time: admin_user_detail_screen.dart carries a hard-coded
-- "Server missing this action — run migration 0015" error string, and the
-- duplicate-username bug came down to public.profiles having been created
-- in the dashboard rather than by a migration, so nobody could say which
-- constraints it carried.
--
-- Each row probes for an artifact that only exists once that migration has
-- run. Where a migration only REPLACES an existing function, the probe
-- looks inside the function body (pg_proc.prosrc) for text unique to the
-- new version — that is the only way to tell a replaced function's
-- version apart, since the name and signature are unchanged.
--
-- A 'no' on anything other than the last row means the database is behind
-- this repository, and the gap is worth closing before trusting any
-- feature that depends on it.

with probe(seq, migration, applied, evidence) as (
  select 1, '0001_lockdown_profiles',
    to_regclass('public.profiles_public') is not null,
    'view profiles_public'
  union all select 2, '0002_admin_roles',
    to_regclass('public.admin_requests') is not null,
    'table admin_requests'
  union all select 3, '0003_refresh_public_key',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'refresh_public_key'),
    'function refresh_public_key'
  union all select 4, '0004_admin_flare_support',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'admin_title'),
    'profiles.admin_title'
  union all select 5, '0005_get_my_status',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'get_my_status'),
    'function get_my_status'
  union all select 6, '0006_account_management',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'delete_hops_user'),
    'function delete_hops_user'
  union all select 7, '0007_email_auth_and_otp',
    to_regclass('public.password_reset_otps') is not null
      and to_regclass('public.email_verification_otps') is not null,
    'OTP tables'
  union all select 8, '0008_admin_moderation',
    to_regclass('public.admin_actions_log') is not null
      and exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'profiles'
                     and column_name = 'banned'),
    'admin_actions_log + profiles.banned'
  union all select 9, '0009_allow_duplicate_signup_emails_for_testing',
    not exists (select 1 from pg_indexes
                 where schemaname = 'public' and indexname = 'profiles_email_unique'),
    'profiles_email_unique DROPPED (testing relaxation — see 0009 header)'
  union all select 10, '0010_notifications_and_logging',
    to_regclass('public.user_notifications') is not null,
    'table user_notifications'
  union all select 11, '0011_report_content_timestamp',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'content_reports'
               and column_name = 'content_created_at'),
    'content_reports.content_created_at'
  union all select 12, '0012_action_log_report_detail',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'resolve_report'),
    'function resolve_report'
  union all select 13, '0013_notify_reporter_on_resolution',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'notify_reporter_of_resolution'),
    'function notify_reporter_of_resolution'
  union all select 14, '0014_reserve_bot_usernames',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'is_reserved_username'),
    'function is_reserved_username'
  union all select 15, '0015_admin_management',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'suspended_until')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'suspend_user'),
    'profiles.suspended_until + function suspend_user'
  union all select 16, '0016_moderation_email_and_log_detail',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'resolve_report'
               and p.prosrc like '%target_email%'),
    'resolve_report returns the target email'
  union all select 17, '0017_report_content_types_study_lost_found',
    exists (select 1 from pg_constraint c
             join pg_class t on t.oid = c.conrelid
             where t.relname = 'content_reports'
               and pg_get_constraintdef(c.oid) like '%study%'),
    'content_reports content_type allows study/lost-found'
  union all select 18, '0018_salted_password_hashing',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'password_salt')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'signup_hops_user'
                     and p.pronargs = 5),
    'profiles.password_salt + signup_hops_user/5'
  union all select 19, '0019_account_change_otp',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'verify_account_otp'),
    'function verify_account_otp'

  -- 0020 gets three separate probes: the index is what stops duplicate
  -- usernames, and the two sign-in functions are what stop a suspended
  -- user signing back in. All three must be present — the index alone
  -- would leave suspension unenforced at sign-in, and vice versa.
  union all select 20, '0020 (a) unique username index',
    exists (select 1 from pg_indexes
             where schemaname = 'public' and indexname = 'profiles_username_unique_ci'),
    'unique index profiles_username_unique_ci on lower(username)'
  union all select 21, '0020 (b) sign-in blocks suspension',
    (select bool_and(p.prosrc like '%account_suspended%')
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('signin_hops_user', 'signin_hops_user_by_email')),
    'both signin functions raise account_suspended'
  union all select 22, '0020 (c) reserved-name check restored',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'signup_hops_user'
               and p.pronargs = 5
               and p.prosrc like '%is_reserved_username%'),
    'signup_hops_user/5 checks is_reserved_username'

  -- 0021 and 0022, same per-half treatment as 0020: each probe covers one
  -- thing that can be missing on its own.
  union all select 23, '0021 (a) institutional domain rule',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'is_allowed_account_email'),
    'function is_allowed_account_email'
  union all select 24, '0021 (b) signup enforces the domain',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'signup_hops_user'
               and p.pronargs = 5
               and p.prosrc like '%is_allowed_account_email%'),
    'signup_hops_user/5 calls is_allowed_account_email'
  union all select 25, '0021 (c) email encryption columns',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'email_encrypted')
      and exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'profiles'
                     and column_name = 'email_lookup'),
    'profiles.email_encrypted + email_lookup'
  union all select 26, '0021 (d) encryption keys configured',
    -- Separate from (c) because 0021 adds the columns but SKIPS the
    -- backfill when the keys are unset, leaving them all null. Columns
    -- present with no keys is a half-done state, not a done one.
    (current_setting('app.email_encryption_key', true) is not null
      and current_setting('app.email_blind_index_key', true) is not null),
    'app.email_encryption_key + app.email_blind_index_key are set'
  union all select 27, '0021 (e) email actually encrypted',
    not exists (select 1 from public.profiles
                 where email is not null and email_encrypted is null),
    'every row with an email has ciphertext (null = backfill never ran)'
  union all select 28, '0022 statistics functions',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('get_admin_stats_range',
                          'get_admin_stats_timeseries',
                          'get_admin_most_active_users',
                          'assert_caller_is_admin')) = 4,
    'all four statistics functions present'
)
select
  migration,
  case
    when applied is null then 'UNKNOWN (object missing entirely)'
    when applied then 'yes'
    else 'NO  <-- not applied'
  end as applied,
  evidence
from probe
order by seq;

-- ---------------------------------------------------------------------------
-- If 0020 (a) comes back NO, check for duplicates BEFORE running it — the
-- migration refuses to proceed while any exist, and this is the list it
-- will complain about.
-- ---------------------------------------------------------------------------
select lower(username) as duplicated_username,
       count(*) as accounts,
       string_agg(id::text, ', ') as profile_ids
  from public.profiles
 where username is not null
 group by lower(username)
having count(*) > 1
 order by lower(username);
