-- crm_tasks1.sql (Benas's side, 11-21): ONE task list (BENAS "build one list first"; Simas's side OK'd the triggers approach).
-- `tasks` is the master. The three old lists keep working: every write to todo_cards (the To-dos board), founder_tasks
-- (crm-api task_add, founder_tasks.py) and call_tasks (call notes) lands in `tasks` by trigger within the same write.
-- Next steps (separate PRs): crm-api tasks/task_add/task_done read+write `tasks`; the To-dos board reads `tasks`;
-- then the old tables stop being written and retire. ADDITIVE ONLY. Rollback: drop the 3 triggers, 5 functions, the view
-- and the table.
--
-- One task = owner (Simas / Benas / Both) · status (todo / doing / done / dropped) · due date (optional; BENAS: no date
-- until a founder gives one) · lead it belongs to · where it came from (source + source_ref) · who created it.
-- Two Claudes never take the same task: task_claim() gives a lease (default 30 min) in one atomic step.

create table if not exists public.tasks (
  id               bigint generated always as identity primary key,
  title            text not null check (char_length(title) between 1 and 300),
  detail           text check (detail is null or char_length(detail) <= 4000),
  owner            text not null default 'Both' check (owner in ('Simas', 'Benas', 'Both')),
  status           text not null default 'todo' check (status in ('todo', 'doing', 'done', 'dropped')),
  due_at           timestamptz,
  lead_email       text,
  big              boolean not null default false,
  pos              double precision not null default 0,         -- order inside a board column
  source           text not null default 'manual' check (source in ('manual', 'board', 'founder_tasks', 'call', 'deferred', 'claude')),
  source_ref       text,                                        -- the row id in the source table
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  done_at          timestamptz,
  claimed_by       text,                                        -- lease: who is working on it right now
  claim_expires_at timestamptz,
  unique (source, source_ref)
);
create index if not exists tasks_open on public.tasks (status, owner, due_at) where status in ('todo', 'doing');

alter table public.tasks enable row level security;
drop policy if exists "founders all" on public.tasks;
create policy "founders all" on public.tasks for all using (public.is_admin()) with check (public.is_admin());
revoke all on public.tasks from anon, authenticated;
grant select, insert, update, delete on public.tasks to authenticated;   -- RLS: founders only (MFA via is_admin)

-- ---------------------------------------------------------------- old lists -> tasks (never blocks the old write)
-- On UPDATE only the fields that changed in the source are copied, so a task moved on the new board is not undone by an
-- unrelated edit to the old row.
create or replace function public.tasks_from_todo_cards() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if tg_op = 'DELETE' then
      delete from public.tasks where source = 'board' and source_ref = old.id::text; return old;
    end if;
    if tg_op = 'INSERT' then
      insert into public.tasks (title, detail, owner, status, due_at, big, pos, source, source_ref, created_by, created_at, updated_at, done_at)
      values (left(new.title, 300), case when char_length(new.title) > 300 then concat_ws(E'\n\n', new.title, new.detail) else new.detail end, coalesce(new.owner, 'Both'), coalesce(new.col, 'todo'),
              case when new.due is null then null else (new.due::text || ' 12:00 Europe/Vilnius')::timestamptz end,
              new.big, new.pos, 'board', new.id::text, new.created_by, new.created_at, new.updated_at,
              case when new.col = 'done' then new.updated_at end)
      on conflict (source, source_ref) do nothing;
    else
      update public.tasks t set
        title   = case when new.title  is distinct from old.title  then left(new.title, 300) else t.title end,
        detail  = case when new.detail is distinct from old.detail then new.detail else t.detail end,
        owner   = case when new.owner  is distinct from old.owner  then coalesce(new.owner, 'Both') else t.owner end,
        status  = case when new.col    is distinct from old.col    then new.col    else t.status end,
        done_at = case when new.col    is distinct from old.col    then (case when new.col = 'done' then now() end) else t.done_at end,
        due_at  = case when new.due    is distinct from old.due    then (case when new.due is null then null else (new.due::text || ' 12:00 Europe/Vilnius')::timestamptz end) else t.due_at end,
        big     = case when new.big    is distinct from old.big    then new.big    else t.big end,
        pos     = case when new.pos    is distinct from old.pos    then new.pos    else t.pos end,
        updated_at = now()
      where t.source = 'board' and t.source_ref = new.id::text;
    end if;
  exception when others then raise warning 'tasks_from_todo_cards skipped %: %', coalesce(new.id, old.id), sqlerrm;
  end;
  return coalesce(new, old);
end $$;

create or replace function public.tasks_from_founder_tasks() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if tg_op = 'DELETE' then
      delete from public.tasks where source = 'founder_tasks' and source_ref = old.id::text; return old;
    end if;
    if tg_op = 'INSERT' then
      insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by, created_at, updated_at, done_at)
      values (left(new.title, 300), case when char_length(new.title) > 300 then concat_ws(E'\n\n', new.title, new.detail) else new.detail end, coalesce(new.who, 'Both'), case when new.done_at is null then 'todo' else 'done' end, new.due_at,
              lower(new.lead_email), 'founder_tasks', new.id::text, new.created_by, new.created_at, new.updated_at, new.done_at)
      on conflict (source, source_ref) do nothing;
    else
      update public.tasks t set
        title      = case when new.title      is distinct from old.title      then left(new.title, 300) else t.title end,
        detail     = case when new.detail     is distinct from old.detail     then new.detail     else t.detail end,
        owner      = case when new.who        is distinct from old.who        then coalesce(new.who, 'Both') else t.owner end,
        due_at     = case when new.due_at     is distinct from old.due_at     then new.due_at     else t.due_at end,
        lead_email = case when new.lead_email is distinct from old.lead_email then lower(new.lead_email) else t.lead_email end,
        status     = case when new.done_at    is distinct from old.done_at    then (case when new.done_at is null then 'todo' else 'done' end) else t.status end,
        done_at    = case when new.done_at    is distinct from old.done_at    then new.done_at    else t.done_at end,
        updated_at = now()
      where t.source = 'founder_tasks' and t.source_ref = new.id::text;
    end if;
  exception when others then raise warning 'tasks_from_founder_tasks skipped %: %', coalesce(new.id, old.id), sqlerrm;
  end;
  return coalesce(new, old);
end $$;

create or replace function public.tasks_from_call_tasks() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if tg_op = 'DELETE' then
      delete from public.tasks where source = 'call' and source_ref = old.id::text; return old;
    end if;
    if tg_op = 'INSERT' then
      insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by, created_at, done_at)
      values (left(new.text, 300), case when char_length(new.text) > 300 then new.text end, coalesce(new.owner, 'Both'),
              case when new.done_at is null then 'todo' else 'done' end, new.due_at, lower(new.lead_email), 'call', new.id::text,
              'call notes', new.created_at, new.done_at)
      on conflict (source, source_ref) do nothing;
    else
      update public.tasks t set
        title      = case when new.text    is distinct from old.text    then left(new.text, 300) else t.title end,
        owner      = case when new.owner   is distinct from old.owner   then coalesce(new.owner, 'Both') else t.owner end,
        due_at     = case when new.due_at  is distinct from old.due_at  then new.due_at  else t.due_at end,
        status     = case when new.done_at is distinct from old.done_at then (case when new.done_at is null then 'todo' else 'done' end) else t.status end,
        done_at    = case when new.done_at is distinct from old.done_at then new.done_at else t.done_at end,
        updated_at = now()
      where t.source = 'call' and t.source_ref = new.id::text;
    end if;
  exception when others then raise warning 'tasks_from_call_tasks skipped %: %', coalesce(new.id, old.id), sqlerrm;
  end;
  return coalesce(new, old);
end $$;

drop trigger if exists tasks_sync on public.todo_cards;
create trigger tasks_sync after insert or update or delete on public.todo_cards for each row execute function public.tasks_from_todo_cards();
drop trigger if exists tasks_sync on public.founder_tasks;
create trigger tasks_sync after insert or update or delete on public.founder_tasks for each row execute function public.tasks_from_founder_tasks();
drop trigger if exists tasks_sync on public.call_tasks;
create trigger tasks_sync after insert or update or delete on public.call_tasks for each row execute function public.tasks_from_call_tasks();

-- ---------------------------------------------------------------- backfill (idempotent)
insert into public.tasks (title, detail, owner, status, due_at, big, pos, source, source_ref, created_by, created_at, updated_at, done_at)
select left(title, 300), case when char_length(title) > 300 then concat_ws(E'\n\n', title, detail) else detail end, coalesce(owner, 'Both'), coalesce(col, 'todo'),
       case when due is null then null else (due::text || ' 12:00 Europe/Vilnius')::timestamptz end,
       big, pos, 'board', id::text, created_by, created_at, updated_at, case when col = 'done' then updated_at end
from public.todo_cards on conflict (source, source_ref) do nothing;
insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by, created_at, updated_at, done_at)
select left(title, 300), case when char_length(title) > 300 then concat_ws(E'\n\n', title, detail) else detail end, coalesce(who, 'Both'), case when done_at is null then 'todo' else 'done' end, due_at, lower(lead_email),
       'founder_tasks', id::text, created_by, created_at, updated_at, done_at
from public.founder_tasks on conflict (source, source_ref) do nothing;
insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by, created_at, done_at)
select left(text, 300), case when char_length(text) > 300 then text end, coalesce(owner, 'Both'),
       case when done_at is null then 'todo' else 'done' end, due_at, lower(lead_email), 'call', id::text, 'call notes', created_at, done_at
from public.call_tasks on conflict (source, source_ref) do nothing;

-- ---------------------------------------------------------------- lease: two Claudes never take the same task
create or replace function public.task_claim(p_id bigint, p_actor text, p_minutes int default 30) returns public.tasks
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.tasks;
begin
  update public.tasks set claimed_by = p_actor, claim_expires_at = now() + make_interval(mins => greatest(1, least(p_minutes, 240))),
         status = case when status = 'todo' then 'doing' else status end, updated_at = now()
   where id = p_id and status in ('todo', 'doing')
     and (claimed_by is null or claim_expires_at < now() or claimed_by = p_actor)
  returning * into r;
  return r;   -- NULL = someone else holds it (or it's done)
end $$;
create or replace function public.task_release(p_id bigint, p_actor text) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.tasks set claimed_by = null, claim_expires_at = null, updated_at = now() where id = p_id and claimed_by = p_actor;
$$;
revoke execute on function public.task_claim(bigint, text, int), public.task_release(bigint, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- the one list the screens read
-- Open tasks plus open promises to clients (read-only rows here; promises stay in their own table with their own rules).
create or replace view public.task_queue with (security_invoker = on) as
select 'task' kind, t.id::text id, t.title, t.detail, t.owner, t.status, t.due_at, t.lead_email, t.source, t.big, t.pos,
       t.claimed_by, (t.claim_expires_at > now()) claimed, t.created_by, t.created_at
from public.tasks t where t.status in ('todo', 'doing')
union all
select 'promise', p.id::text, p.promise, null, coalesce(p.owner, 'Both'), 'todo', p.due_at, p.lead_email, 'promise', false, 0::double precision,
       null, false, p.created_by, p.created_at
from public.promises p where p.status = 'open';
revoke all on public.task_queue from anon, authenticated;
grant select on public.task_queue to authenticated;
