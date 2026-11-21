-- crm_audit1.sql (11-21, SIMAS: "we can both adjust it but we need to make sure everything is perfect and nothing will
-- overwright"). Two founders + two Claudes write the same rows; this keeps a record of every real change.
-- Additive only: audit_log, one generic trigger function, founder_tasks.updated_at (+ its touch trigger, so crm-api can
-- refuse stale writes with 409), AFTER triggers on the shared tables. Needs crm_notify1.sql (crm_actor, crm_source).
--   changed = only the fields that changed, {"field": [old, new]}; the whole row on insert / delete.
--   An update that changes nothing (or only updated_at, or an ignored column) writes NO row.
--   actor  = the founder's name for a page session (cannot be faked with a header), else header x-actor (crm-api,
--            crm.py, crm_desk.py), else 'service'.   source = header x-source, else 'page' for founders, else 'script'.
-- Trigger args: (key column, optional filter). Filter '-a,b' ignores columns a and b; '+a,b' records ONLY a and b.
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_audit1.sql

create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  table_name text not null,
  row_key    text,
  op         text not null,
  actor      text,
  source     text,
  changed    jsonb
);
create index if not exists audit_log_at on public.audit_log (at desc);
create index if not exists audit_log_row on public.audit_log (table_name, row_key, at desc);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
drop policy if exists "founders read" on public.audit_log;
create policy "founders read" on public.audit_log for select using (public.is_admin());
grant select on public.audit_log to authenticated;            -- nobody but the triggers writes

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  key_col   text := tg_argv[0];
  filt      text := coalesce(tg_argv[1], '');
  only_cols text[];
  skip_cols text[] := array['updated_at'];
  o  jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n  jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  ch jsonb := '{}'::jsonb;
  k  text;
begin
  if left(filt, 1) = '+' then only_cols := string_to_array(substr(filt, 2), ',');
  elsif left(filt, 1) = '-' then skip_cols := skip_cols || string_to_array(substr(filt, 2), ',');
  end if;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k = any(skip_cols) or (only_cols is not null and not (k = any(only_cols))) then continue; end if;
      if (o -> k) is distinct from (n -> k) then ch := ch || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k)); end if;
    end loop;
    if ch = '{}'::jsonb then return null; end if;          -- no-op update: nothing to record
  else
    ch := coalesce(n, o) - skip_cols;
    if only_cols is not null then
      select coalesce(jsonb_object_agg(j.key, j.value), '{}'::jsonb) into ch from jsonb_each(ch) j where j.key = any(only_cols);
    end if;
  end if;
  insert into public.audit_log (table_name, row_key, op, actor, source, changed)
  values (tg_table_name, coalesce(n, o) ->> key_col, lower(tg_op), public.crm_actor(), public.crm_source(), ch);
  return null;
exception when others then
  raise warning 'audit_row %.% failed: %', tg_table_name, tg_op, sqlerrm;   -- the audit never blocks a business write
  return null;
end $$;
revoke all on function public.audit_row() from public, anon, authenticated;

-- founder_tasks gets updated_at (crm-api task_done checks it for optimistic locking; the page can too: ?updated_at=eq.<seen>)
alter table public.founder_tasks add column if not exists updated_at timestamptz not null default now();
create or replace function public.founder_tasks_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists founder_tasks_touch on public.founder_tasks;
create trigger founder_tasks_touch before update on public.founder_tasks for each row execute function public.founder_tasks_touch();
revoke all on function public.founder_tasks_touch() from public, anon, authenticated;

drop trigger if exists audit on public.desk_items;
create trigger audit after insert or update or delete on public.desk_items    for each row execute function public.audit_row('id');
drop trigger if exists audit on public.founder_tasks;
create trigger audit after insert or update or delete on public.founder_tasks for each row execute function public.audit_row('id');
drop trigger if exists audit on public.touches;
create trigger audit after insert or update or delete on public.touches       for each row execute function public.audit_row('id');
drop trigger if exists audit on public.opportunities;
create trigger audit after insert or update or delete on public.opportunities for each row execute function public.audit_row('id');
drop trigger if exists audit on public.deal_stages;
create trigger audit after insert or update or delete on public.deal_stages   for each row execute function public.audit_row('stage');
drop trigger if exists audit on public.api_keys;   -- last_used_at moves on every call; the hash is never copied
create trigger audit after insert or update or delete on public.api_keys      for each row execute function public.audit_row('name', '-last_used_at,key_hash');
drop trigger if exists audit on public.clients;
create trigger audit after insert or update or delete on public.clients       for each row execute function public.audit_row('id');
drop trigger if exists audit on public.promises;
create trigger audit after insert or update or delete on public.promises      for each row execute function public.audit_row('id');
-- pipeline: see the PIPELINE block appended below after the no-op measurement.
