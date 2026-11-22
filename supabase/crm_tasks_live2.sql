-- crm_tasks_live2.sql (Benas's Claude, 2026-11-22): follow-up to crm_tasks_live1.sql (PR #16 review gap).
-- A reply task dropped because its lead was snoozed now reopens when the snooze ends and the same reply is still waiting.
-- Only reply_tasks_sync() changes; run after crm_tasks_live1.sql. Re-run safe.

create or replace function public.reply_tasks_sync() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; c int := 0; l int := 0; r int := 0;
begin
  insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by)
  select format('Reply to %s', coalesce(nullif(w.name, ''), w.lead_email)),
         left(trim(public.reply_own_words(w.snippet)), 300),
         case when w.owner in ('Simas', 'Benas') then w.owner else public.inbox_owner(w.inbox) end,
         'todo', w.received_at, w.lead_email, 'reply', w.ref, 'reply-tasks'
    from public.reply_wait() w
  on conflict (source, source_ref) do nothing;
  get diagnostics n = row_count;

  -- 11-22 review (Simas's Claude): a reply task dropped while its lead was snoozed (or briefly lost) must come back when the same
  -- reply is waiting again; ON CONFLICT above leaves the old dropped row, so reopen it here
  update public.tasks t set status = 'todo', done_at = null, updated_at = now()
   where t.source = 'reply' and t.status = 'dropped'
     and exists (select 1 from public.reply_wait() w where w.ref = t.source_ref);
  get diagnostics r = row_count;
  n := n + r;

  -- a reply task closes itself once its reply stops waiting: we answered (done) or it was dismissed / blocklisted /
  -- turned out to be noise / the lead went lost or snoozed / a newer reply replaced it (dropped; the newer one gets its own task)
  update public.tasks t
     set status = case when exists (select 1 from public.reply_queue r where lower(r.lead_email) = t.lead_email
                                     and r.received_at = t.due_at and r.answered)
                         or exists (select 1 from public.threads h where lower(h.lead_email) = t.lead_email
                                     and h.direction = 'out' and h.at > t.due_at)
                       then 'done' else 'dropped' end,
         done_at = now(), updated_at = now()
   where t.source = 'reply' and t.status in ('todo', 'doing')
     and not exists (select 1 from public.reply_wait() w where w.ref = t.source_ref);
  get diagnostics c = row_count;

  -- a lost reason closes the lead's automatic tasks (reply + no-reply follow-up reminders); founder and board tasks stay
  update public.tasks t set status = 'dropped', done_at = now(), updated_at = now()
   where t.source in ('reply', 'claude') and t.status in ('todo', 'doing') and t.lead_email is not null
     and exists (select 1 from public.lead_flags f where f.email = lower(t.lead_email) and f.lost_reason is not null);
  get diagnostics l = row_count;

  insert into public.sync_status (name, ran_at, ok, detail)
  values ('reply_tasks', now(), true, format('%s new or reopened (%s reopened), %s closed, %s closed (lost lead)', n, r, c, l))
  on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  return n;
end $$;
revoke execute on function public.reply_tasks_sync() from public, anon, authenticated;
