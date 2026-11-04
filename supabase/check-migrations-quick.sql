-- Quick migration check — ONE query, safe to paste whole.
--
-- The companion to check-applied-migrations.sql, which probes all 22 and
-- holds two separate queries. This is the short form: the three migrations
-- that are currently outstanding, plus enough older landmarks to show
-- whether the database is further behind than expected.
--
-- Supabase dashboard -> your project -> SQL Editor -> New query -> paste
-- -> Run. Read-only.
--
-- Expected right now: the 00xx landmark rows all 'yes', and every 0020 /
-- 0021 / 0022 row 'NO'. Anything before 0020 reading 'NO' means the
-- database is behind in a way worth investigating before applying more.

select '0008 moderation tables' as item,
       case when to_regclass('public.admin_actions_log') is not null
            then 'yes' else 'NO' end as applied
union all
select '0015 suspend_user exists',
       case when exists (select 1 from pg_proc p
                           join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public'
                            and p.proname = 'suspend_user')
            then 'yes' else 'NO' end
union all
select '0018 salted passwords',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public'
                            and table_name = 'profiles'
                            and column_name = 'password_salt')
            then 'yes' else 'NO' end
union all
select '0019 verify_account_otp',
       case when exists (select 1 from pg_proc p
                           join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public'
                            and p.proname = 'verify_account_otp')
            then 'yes' else 'NO' end
union all
-- 0020: the one that makes suspend and ban actually work.
select '0020a unique username index',
       case when exists (select 1 from pg_indexes
                          where schemaname = 'public'
                            and indexname = 'profiles_username_unique_ci')
            then 'yes' else 'NO' end
union all
select '0020b sign-in blocks suspension',
       case when coalesce((select bool_and(p.prosrc like '%account_suspended%')
                             from pg_proc p
                             join pg_namespace n on n.oid = p.pronamespace
                            where n.nspname = 'public'
                              and p.proname in ('signin_hops_user',
                                                'signin_hops_user_by_email')),
                          false)
            then 'yes' else 'NO' end
union all
select '0021a domain rule function',
       case when exists (select 1 from pg_proc p
                           join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public'
                            and p.proname = 'is_allowed_account_email')
            then 'yes' else 'NO' end
union all
select '0021b email encryption columns',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public'
                            and table_name = 'profiles'
                            and column_name = 'email_encrypted')
            then 'yes' else 'NO' end
union all
-- Separate from 0021b on purpose: 0021 adds the columns but SKIPS its
-- backfill when the keys are unavailable, leaving every value null.
-- Columns present with no keys is a half-done state, not a done one.
--
-- Reads Vault, not a database parameter — `alter database ... set` needs
-- superuser and cannot work on Supabase, which is why 0021 uses Vault.
select '0021c Vault keys present',
       case when coalesce((select count(*) >= 2
                             from vault.decrypted_secrets
                            where name in ('hops_email_encryption_key',
                                           'hops_email_blind_index_key')),
                          false)
            then 'yes' else 'NO' end
union all
select '0022 statistics functions',
       case when (select count(*) from pg_proc p
                    join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public'
                     and p.proname in ('get_admin_stats_range',
                                       'get_admin_stats_timeseries',
                                       'get_admin_most_active_users',
                                       'assert_caller_is_admin')) = 4
            then 'yes' else 'NO' end
union all
-- The row that actually proves encryption works: ciphertext present AND
-- it decrypts back to the original. 'partial' means the backfill ran
-- against some rows only.
select '0021d email actually encrypted',
       case
         when not exists (select 1 from information_schema.columns
                           where table_schema = 'public'
                             and table_name = 'profiles'
                             and column_name = 'email_encrypted')
           then 'n/a - 0021 not applied'
         when (select count(*) from public.profiles where email is not null) = 0
           then 'n/a - no emails stored'
         when (select count(*) from public.profiles
                where email is not null and email_encrypted is null) = 0
           then 'yes'
         when (select count(*) from public.profiles
                where email is not null and email_encrypted is not null) > 0
           then 'partial - re-run 0021'
         else 'NO - backfill never ran'
       end
union all
-- Not a migration: 0020 refuses to run while any duplicate exists, so
-- this is folded in here to save running a second query for it.
select 'duplicate usernames present',
       case when exists (select 1 from public.profiles
                          where username is not null
                          group by lower(username)
                         having count(*) > 1)
            then 'YES - resolve before 0020' else 'no' end
order by 1;
