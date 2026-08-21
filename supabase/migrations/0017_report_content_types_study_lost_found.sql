-- 0017_report_content_types_study_lost_found.sql
--
-- Adds 'study_bunny' and 'lost_found' to content_reports' content_type
-- check constraint (see 0008_admin_moderation.sql) — the Report button on
-- both new features (client/lib/views/study_bunny_finder_page.dart,
-- lost_found_board_page.dart) calls submit_report with these values, same
-- as Vibe Check's 'vibe_check' already does, and both are the same shape:
-- anonymous, sender-less broadcast content, so target_username stays null
-- for these too (see 0008's comment on that column).
--
-- Postgres has no "alter check constraint" — drop and recreate under the
-- same name.
alter table public.content_reports
  drop constraint content_reports_content_type_check;

alter table public.content_reports
  add constraint content_reports_content_type_check
  check (content_type in ('chat_message', 'vibe_check', 'contact_profile', 'study_bunny', 'lost_found'));
