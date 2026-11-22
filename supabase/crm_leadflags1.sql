-- crm_leadflags1.sql (Benas's side, 11-21): BENAS picked from the pro-CRM research (17:4x): LOST REASONS, SNOOZE, and
-- REMIND-IF-NO-REPLY (after our price / plan / scope email). Data only; screens are Simas's side. Additive.
-- Rollback: select cron.unschedule('offer-reminders'); drop function offer_reminders_to_tasks(); drop view
-- offer_followups_due, lost_reasons_by_campaign; drop table lead_flags;

-- ---------------------------------------------------------------- lost reasons + snooze (one row per lead)
create table if not exists public.lead_flags (
  email         text primary key check (email = lower(email) and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  lost_reason   text check (lost_reason in ('price', 'timing', 'no_budget', 'not_a_fit', 'has_editor', 'no_reply',
                                            'hard_no', 'went_elsewhere', 'other')),
  lost_note     text check (lost_note is null or char_length(lost_note) <= 500),
  lost_at       timestamptz,
  snoozed_until timestamptz,                    -- hidden from the work lists until then; comes back by itself
  snooze_note   text check (snooze_note is null or char_length(snooze_note) <= 500),
  updated_by    text,
  updated_at    timestamptz not null default now()
);
alter table public.lead_flags enable row level security;
drop policy if exists "founders all" on public.lead_flags;
create policy "founders all" on public.lead_flags for all using (public.is_admin()) with check (public.is_admin());
revoke all on public.lead_flags from anon, authenticated;
grant select, insert, update on public.lead_flags to authenticated;
drop trigger if exists audit on public.lead_flags;
create trigger audit after insert or update or delete on public.lead_flags for each row execute function public.audit_row('email');

-- reported per campaign (the lead's campaign from pipeline / interested_leads)
create or replace view public.lost_reasons_by_campaign with (security_invoker = on) as
select coalesce(p.campaign, i.campaign, '(unknown)') campaign, f.lost_reason, count(*)::int leads, max(f.lost_at) last_at
from public.lead_flags f
left join public.pipeline p on lower(p.email) = f.email
left join public.interested_leads i on lower(i.email) = f.email
where f.lost_reason is not null
group by 1, 2
order by 1, 3 desc;
revoke all on public.lost_reasons_by_campaign from anon, authenticated;
grant select on public.lost_reasons_by_campaign to authenticated;

-- ---------------------------------------------------------------- remind if no reply
-- Our FIRST email after the lead's last message that named a price or linked a plan / scope / payment page, then
-- silence: follow-up 1 is due 2 days after it, follow-up 2 three days after follow-up 1, then nothing (max two
-- follow-ups, then park). Counting from the first offer after their last message means a follow-up that repeats the
-- price never restarts the count. Not for leads that are snoozed, lost, won / parked, or on a hold; only reminders
-- that fell due in the last 7 days (older silence = parked by the max-two rule, no flood on the first run).
create or replace view public.offer_followups_due with (security_invoker = on) as
with last_in as (
  select lower(lead_email) e, max(at) at from public.threads where direction = 'in' group by 1
), offer as (
  select lower(t.lead_email) e, min(t.at) at
  from public.threads t left join last_in li on li.e = lower(t.lead_email)
  where t.direction = 'out' and t.body is not null and t.at > coalesce(li.at, '-infinity'::timestamptz)
    and (t.body ~* '(buy\.stripe\.com|bejucreative\.digital/(plans|scope)/)' or t.body ~* '\$\s?\d{2,}|\m\d{2,5} ?usd\M')
  group by 1
), after as (
  select o.e, o.at offer_at,
         (select count(*) from public.threads t where lower(t.lead_email) = o.e and t.direction = 'out' and t.at > o.at)::int fus,
         (select max(at) from public.threads t where lower(t.lead_email) = o.e and t.direction = 'out') last_out
  from offer o
), due as (
  select a.*, case when a.fus = 0 then a.offer_at + interval '2 days' else a.last_out + interval '3 days' end due_at
  from after a where a.fus < 2
)
select d.e lead_email, d.offer_at, d.fus followups_done, d.fus + 1 followup_no, d.due_at,
       ls.name, coalesce(ls.owner, 'Both') owner, ls.stage
from due d
left join public.lead_stage ls on ls.email = d.e
left join public.lead_flags f on f.email = d.e
where now() >= d.due_at
  -- 7-day window counted from the later of the due date and the snooze end, so a snoozed lead comes back when it ends
  and greatest(d.due_at, coalesce(f.snoozed_until, d.due_at)) > now() - interval '7 days'
  and coalesce(ls.stage, '') not in ('won', 'lost', 'parked')
  and f.lost_reason is null
  and (f.snoozed_until is null or f.snoozed_until <= now())
  and not exists (select 1 from public.desk_items h where h.kind = 'hold' and h.status = 'open' and d.e = any(h.emails))
  -- one source per lead (review 19:57): leads in the sample follow-up cadence (fu_state active) get their reminders
  -- from that cadence (crm.due / the 13:30 FOLLOW-UPS DUE alert), not from here
  and not exists (select 1 from public.fu_state s where lower(s.email) = d.e and s.state = 'active');
revoke all on public.offer_followups_due from anon, authenticated;
grant select on public.offer_followups_due to authenticated;

-- hourly: each due follow-up becomes ONE task for the lead's owner (source 'claude', source_ref 'nofu:<email>:<n>',
-- so a re-run never duplicates). The drafting Claude writes the follow-up (lane 1, the other Claude checks it).
create or replace function public.offer_reminders_to_tasks() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0;
begin
  insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by)
  select format('Follow up %s (no reply to our price / plan email, FU %s of 2)', coalesce(nullif(d.name, ''), d.lead_email), d.followup_no),
         format('Our offer went %s; %s follow-up(s) since; no reply. Max two follow-ups, then park.',
                to_char(d.offer_at at time zone 'Europe/Vilnius', 'YYYY-MM-DD HH24:MI'), d.followups_done),
         case when d.owner in ('Simas', 'Benas') then d.owner else 'Both' end, 'todo', d.due_at, d.lead_email,
         'claude', 'nofu:' || d.lead_email || ':' || d.followup_no, 'offer-reminders'
  from public.offer_followups_due d
  on conflict (source, source_ref) do nothing;
  get diagnostics n = row_count;
  -- a reminder closes itself once the thread moves: we wrote after it (done) or the lead wrote (dropped; their reply
  -- goes through the normal reply lanes)
  update public.tasks t
     set status = case when exists (select 1 from public.threads h where lower(h.lead_email) = lower(t.lead_email)
                                     and h.direction = 'out' and h.at > t.created_at) then 'done' else 'dropped' end,
         done_at = now(), updated_at = now()
   where t.source = 'claude' and t.source_ref like 'nofu:%' and t.status in ('todo', 'doing')
     and exists (select 1 from public.threads h where lower(h.lead_email) = lower(t.lead_email) and h.at > t.created_at);
  insert into public.sync_status (name, ran_at, ok, detail) values ('offer_reminders', now(), true, n || ' new follow-up task(s)')
  on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  return n;
end $$;
revoke execute on function public.offer_reminders_to_tasks() from public, anon, authenticated;

select cron.unschedule('offer-reminders') where exists (select 1 from cron.job where jobname = 'offer-reminders');
select cron.schedule('offer-reminders', '7 * * * *', $$select public.offer_reminders_to_tasks()$$);

-- the work lists hide snoozed leads: task_queue keeps its columns and drops rows whose lead is snoozed or lost
create or replace view public.task_queue with (security_invoker = on) as
select q.* from (
  select 'task' kind, t.id::text id, t.title, t.detail, t.owner, t.status, t.due_at, t.lead_email, t.source, t.big, t.pos,
         t.claimed_by, (t.claim_expires_at > now()) claimed, t.created_by, t.created_at
  from public.tasks t where t.status in ('todo', 'doing')
  union all
  select 'promise', p.id::text, p.promise, null, coalesce(p.owner, 'Both'), 'todo', p.due_at, p.lead_email, 'promise', false, 0::double precision,
         null, false, p.created_by, p.created_at
  from public.promises p where p.status = 'open'
  union all
  select 'approval', d.id::text, format('Approve the reply to %s (%s)', d.lead_email, replace(d.category, '_', ' ')), d.reason, 'Both',
         case when d.status = 'held' then 'doing' else 'todo' end, null, d.lead_email, 'approval', true, 0::double precision,
         null, false, d.created_by, d.created_at
  from public.drafts d where d.status in ('pending', 'held', 'unknown')
) q
left join public.lead_flags f on f.email = lower(q.lead_email)
where q.kind = 'approval' or f.email is null or ((f.snoozed_until is null or f.snoozed_until <= now()) and f.lost_reason is null);
revoke all on public.task_queue from anon, authenticated;
grant select on public.task_queue to authenticated;
