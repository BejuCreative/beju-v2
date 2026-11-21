-- Rollback of crm_callnotes1.sql (call notes in the client / lead profile, 11-21). Deletes the call tasks and the three
-- touches columns with their data. The touches rows themselves (summary etc.) stay.
drop table if exists public.call_tasks;
drop index if exists public.touches_call_uid;
revoke update (takeaways, recording_url) on public.touches from authenticated;
alter table public.touches drop column if exists recording_url;
alter table public.touches drop column if exists takeaways;
alter table public.touches drop column if exists call_uid;
