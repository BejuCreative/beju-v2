-- 11-21 (SIMAS): "where we could put all of our meetings and how we could track the information in the CRM ... short summaries
-- of the call and key takeaways and next tasks that we have to do for them". Shown as a "Calls" section at the bottom of the
-- client / lead profile (no new tab). Additive only: three columns + one index on touches, one new table. Rollback:
-- crm_callnotes1_rollback.sql.
--
-- A call's notes = ONE touches row (kind 'call') with call_uid = calls.uid: summary (2-3 short lines), takeaways (3-5 bullets),
-- recording_url. Its next tasks live in call_tasks (one row each, owner Simas / Benas / Both, due date, done tick).
-- Why a separate call_tasks table and not founder_tasks: each task must point at its call (touch_id), the owner must be one of
-- three values, and founders may only tick it (done_at, done_by). One clear table, so the "one task list" merge can take it whole.

-- 1) touches: which call the notes are about, the takeaways, the recording / transcript link
alter table public.touches add column if not exists call_uid text references public.calls (uid) on delete set null;
alter table public.touches add column if not exists takeaways text[];
alter table public.touches add column if not exists recording_url text;
create unique index if not exists touches_call_uid on public.touches (call_uid) where call_uid is not null;   -- one notes row per call
grant update (takeaways, recording_url) on public.touches to authenticated;   -- founders fix their own notes (RLS "founders edit")

-- 2) call_tasks: the next tasks from a call
create table if not exists public.call_tasks (
  id         bigint generated always as identity primary key,
  touch_id   bigint not null references public.touches (id) on delete cascade,
  lead_email text not null,
  text       text not null,
  owner      text not null check (owner in ('Simas', 'Benas', 'Both')),
  due_at     timestamptz,
  done_at    timestamptz,
  done_by    text,
  created_at timestamptz not null default now()
);
create index if not exists call_tasks_touch on public.call_tasks (touch_id);
create index if not exists call_tasks_lead on public.call_tasks (lower(lead_email));
create index if not exists call_tasks_open on public.call_tasks (owner, due_at) where done_at is null;
alter table public.call_tasks enable row level security;
revoke all on public.call_tasks from anon, authenticated;
drop policy if exists "founders read" on public.call_tasks;
drop policy if exists "founders add" on public.call_tasks;
drop policy if exists "founders tick" on public.call_tasks;
create policy "founders read" on public.call_tasks for select using (public.is_admin());
create policy "founders add"  on public.call_tasks for insert with check (public.is_admin());
create policy "founders tick" on public.call_tasks for update using (public.is_admin()) with check (public.is_admin());
grant select, insert on public.call_tasks to authenticated;
grant update (done_at, done_by) on public.call_tasks to authenticated;   -- ticking only; text, owner and due stay as written
drop trigger if exists audit on public.call_tasks;
create trigger audit after insert or update or delete on public.call_tasks for each row execute function public.audit_row('id');
