-- crm_notify1.sql (11-21, SIMAS: "add greater notifications in the crm, make them interactive also").
-- Additive only: two new tables, one view, helper functions, AFTER triggers on the source tables, realtime, a 7-day backfill.
--   crm_events       one row per thing worth a founder's eye. ref is the dedup key, so the hourly Mac sync that deletes and
--                    re-inserts reply_queue (and every other re-run) never raises the same event twice.
--   crm_event_state  each founder's own read / snooze / done per event (RLS: only your own rows).
--   crm_inbox        crm_events + the CALLER's state, with is_unread.
-- Triggers never block the write they sit on: crm_event_add swallows its own errors (warning only), and every trigger
-- function is SECURITY DEFINER, so a portal client's sample insert or a founder's touch can still raise an event.
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_notify1.sql

create table if not exists public.crm_events (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  kind       text not null check (kind in ('reply','hot','payment','booking','sample','hold','task','touch','stage','slack','alert')),
  severity   text not null default 'info' check (severity in ('info','hot','money','alert')),
  title      text not null,
  body       text,
  lead_email text,
  link       text,
  source     text,
  ref        text unique,
  actor      text
);
create index if not exists crm_events_at on public.crm_events (at desc);
create index if not exists crm_events_lead on public.crm_events (lower(lead_email), at desc);
alter table public.crm_events enable row level security;
revoke all on public.crm_events from anon, authenticated;
drop policy if exists "founders read" on public.crm_events;
create policy "founders read" on public.crm_events for select using (public.is_admin());
grant select on public.crm_events to authenticated;          -- writes: triggers + service role only

create table if not exists public.crm_event_state (
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  event_id      bigint not null references public.crm_events(id) on delete cascade,
  read_at       timestamptz,
  snoozed_until timestamptz,
  done_at       timestamptz,
  primary key (user_id, event_id)
);
create index if not exists crm_event_state_event on public.crm_event_state (event_id);
alter table public.crm_event_state enable row level security;
revoke all on public.crm_event_state from anon, authenticated;
drop policy if exists "own state read" on public.crm_event_state;
drop policy if exists "own state add" on public.crm_event_state;
drop policy if exists "own state edit" on public.crm_event_state;
drop policy if exists "own state delete" on public.crm_event_state;
create policy "own state read"   on public.crm_event_state for select using (user_id = auth.uid() and public.is_admin());
create policy "own state add"    on public.crm_event_state for insert with check (user_id = auth.uid() and public.is_admin());
create policy "own state edit"   on public.crm_event_state for update using (user_id = auth.uid() and public.is_admin())
                                                                     with check (user_id = auth.uid() and public.is_admin());
create policy "own state delete" on public.crm_event_state for delete using (user_id = auth.uid() and public.is_admin());
grant select, insert, update, delete on public.crm_event_state to authenticated;

-- The bell: every event + MY state. Snoozed = snoozed_until in the future.
create or replace view public.crm_inbox with (security_invoker = on) as
select e.id, e.at, e.kind, e.severity, e.title, e.body, e.lead_email, e.link, e.source, e.actor,
       s.read_at, s.snoozed_until, s.done_at,
       (s.read_at is null and (s.snoozed_until is null or s.snoozed_until <= now()) and s.done_at is null) as is_unread
  from public.crm_events e
  left join public.crm_event_state s on s.event_id = e.id and s.user_id = auth.uid();
revoke all on public.crm_inbox from anon, authenticated;
grant select on public.crm_inbox to authenticated;

-- "Mark all read" in one call (RLS applies: it only ever writes the caller's own rows).
create or replace function public.crm_mark_all_read(p_before timestamptz default now())
returns int language sql security invoker set search_path = public as $$
  with x as (
    insert into public.crm_event_state (user_id, event_id, read_at)
    select auth.uid(), e.id, now() from public.crm_events e where e.at <= p_before
    on conflict (user_id, event_id) do update set read_at = coalesce(public.crm_event_state.read_at, excluded.read_at)
    returning 1)
  select count(*)::int from x
$$;
revoke all on function public.crm_mark_all_read(timestamptz) from public, anon;
grant execute on function public.crm_mark_all_read(timestamptz) to authenticated;

-- ---------- helpers (definer, NOT callable by anon/authenticated) ----------
create or replace function public.crm_event_add(p_kind text, p_severity text, p_title text, p_body text, p_lead text,
                                                p_link text, p_source text, p_ref text, p_actor text, p_at timestamptz default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.crm_events (at, kind, severity, title, body, lead_email, link, source, ref, actor)
  values (coalesce(p_at, now()), p_kind, coalesce(p_severity, 'info'), left(coalesce(nullif(p_title, ''), p_kind), 300), left(p_body, 2000),
          lower(nullif(trim(p_lead), '')), p_link, p_source, p_ref, left(p_actor, 80))
  on conflict (ref) do nothing;
exception when others then
  raise warning 'crm_event_add % failed: %', p_ref, sqlerrm;       -- never block the write that raised it
end $$;

create or replace function public.crm_lead_label(p_email text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(trim(p.name), '') from public.pipeline p where p.email = lower(trim(p_email)) limit 1),
    (select nullif(concat_ws(' · ', nullif(trim(i.first_name), ''), nullif(trim(i.company), '')), '') from public.interested_leads i where i.email = lower(trim(p_email)) limit 1),
    (select c.name from public.clients c where lower(trim(p_email)) = any(c.emails) limit 1),
    lower(trim(p_email)))
$$;

create or replace function public.crm_money(a numeric) returns text language sql immutable as $$
  select '$' || case when a = trunc(a) then trunc(a)::text else round(a, 2)::text end
$$;

create or replace function public.crm_ts(t timestamptz) returns text language sql immutable as $$
  select to_char(t at time zone 'UTC', 'YYYYMMDD"T"HH24MISS')
$$;

-- Who / from where a write came (also used by audit_log, crm_audit1.sql). A founder's session wins (it cannot be faked
-- with a header); else header x-actor (crm-api, crm.py), else the beju.actor setting, else 'service'.
create or replace function public.crm_actor() returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare h json; n text; uid uuid := auth.uid();
begin
  if uid is not null then select p.name into n from public.profiles p where p.id = uid; end if;
  if nullif(n, '') is not null then return n; end if;
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  return left(coalesce(nullif(h ->> 'x-actor', ''), nullif(current_setting('beju.actor', true), ''), 'service'), 80);
end $$;

create or replace function public.crm_source() returns text
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  return left(coalesce(nullif(h ->> 'x-source', ''), case when auth.uid() is not null then 'page' else 'script' end), 40);
end $$;

-- ---------- one builder per source (the triggers AND the backfill call these) ----------
create or replace function public.crm_ev_payment(r public.payments, p_source text default 'stripe') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if r.email is not null and exists (select 1 from public.payments p where p.id <> r.id and lower(p.email) = lower(r.email)
       and p.amount = r.amount and abs(extract(epoch from p.paid_at - r.paid_at)) < 7200) then
    return;   -- the webhook's cs_ row + the Mac sync's charge row are the same money (crm_sync.py 2b): one bell, not two
  end if;
  perform public.crm_event_add('payment', 'money',
    'Paid ' || public.crm_money(r.amount) || case when coalesce(lower(r.currency), 'usd') <> 'usd' then ' ' || upper(r.currency) else '' end
      || ' · ' || coalesce(nullif(r.payer_name, ''), public.crm_lead_label(r.email), 'unknown payer'),
    concat_ws(' · ', r.package, r.description, case when r.refunded then 'refunded' end),
    r.email, null, p_source, 'pay:' || r.id, 'stripe', r.paid_at);
end $$;

create or replace function public.crm_ev_call(r public.calls, p_cancelled boolean, p_source text default 'cal.com') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare who text := coalesce(nullif(r.name, ''), public.crm_lead_label(r.email));
        slot text := to_char(r.start_at at time zone 'Europe/Vilnius', 'Dy DD Mon HH24:MI') || ' Vilnius';
begin
  if p_cancelled then
    perform public.crm_event_add('booking', 'info', 'Call cancelled: ' || who || ' (' || slot || ')', r.title, r.email, null,
                                 p_source, 'call:' || r.uid || ':cancelled', 'cal.com', coalesce(r.updated_at, now()));
  else
    perform public.crm_event_add('booking', 'hot', 'Call booked: ' || who || ' · ' || slot, r.title, r.email, r.meet_url,
                                 p_source, 'call:' || r.uid, 'cal.com', coalesce(r.booked_at, now()));
  end if;
end $$;

-- A REAL reply. Hot = Instantly marked them Interested, they sit in asked_price / said_yes, or the text asks about price or
-- says yes; a plain "no" / hard pass is never hot.
create or replace function public.crm_ev_reply(r public.reply_queue, p_source text default 'instantly') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e text := lower(trim(r.lead_email)); s text := coalesce(r.snippet, ''); sev text := 'info';
begin
  if r.kind is distinct from 'REAL' or coalesce(r.blocklisted, false) or e is null then return; end if;
  if s !~* '(not interested|no,? thanks|no thank you|unsubscribe|remove me|stop (emailing|contacting)|not a (good )?fit|we.?ll pass|not for (us|me)|take me off)'
     and (exists (select 1 from public.interested_leads i where i.email = e)
          or exists (select 1 from public.pipeline p where p.email = e and p.fu_stage in ('asked_price', 'said_yes'))
          or s ~* '(price|pricing|cost|how much|rates\M|quote|budget|invoice|payment link|sign (me|us) up|let.?s do (it|this)|sounds (good|great)|i.?m interested|we.?re interested|book (a|the) call|send (me |us )?(the |a )?link)')
  then sev := 'hot'; end if;
  perform public.crm_event_add('reply', sev, 'Reply from ' || public.crm_lead_label(e),
                               left(s, 600) || coalesce(' (to ' || r.inbox || ')', ''), e, null, p_source,
                               'reply:' || e || ':' || public.crm_ts(r.received_at), 'lead', r.received_at);
end $$;

create or replace function public.crm_ev_interested(r public.interested_leads, p_source text default 'instantly') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_event_add('hot', 'hot', 'Marked interested: ' || public.crm_lead_label(r.email),
    concat_ws(' · ', 'campaign ' || r.campaign, 'inbox ' || r.inbox, r.reply_count || ' replies'), r.email, null, p_source,
    'hot:' || lower(r.email) || ':' || coalesce(public.crm_ts(r.interest_changed_at), '0'), 'instantly', coalesce(r.interest_changed_at, now()));
end $$;

create or replace function public.crm_ev_sample(r public.sample_requests, p_source text default 'portal') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare pn text; pe text;
begin
  select p.name, p.email into pn, pe from public.profiles p where p.id = r.user_id;
  perform public.crm_event_add('sample', 'hot', 'Portal sample request: ' || coalesce(nullif(pn, ''), pe, 'a client'),
    concat_ws(' · ', r.moment, r.goal, r.style, r.video_url), pe, r.video_url, p_source, 'sample:' || r.id, coalesce(nullif(pn, ''), pe), r.created_at);
end $$;

-- Samples-sheet status moves that matter (stage_log, written by pipeline's own log_stage trigger).
create or replace function public.crm_ev_stage(r public.stage_log, p_source text default 'pipeline') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare st text := upper(coalesce(r.to_status, '')); who text := public.crm_lead_label(r.lead_email); k text; sev text; t text;
begin
  case st
    when 'YES'       then k := 'sample'; sev := 'hot';   t := 'Sample yes: ' || who;
    when 'DELIVERED' then k := 'sample'; sev := 'info';  t := 'Sample delivered: ' || who;
    when 'HOT'       then k := 'stage';  sev := 'hot';   t := 'Hot lead: ' || who;
    when 'WON'       then k := 'stage';  sev := 'money'; t := 'Won: ' || who;
    when 'LOST'      then k := 'stage';  sev := 'info';  t := 'Lost: ' || who;
    else return;
  end case;
  perform public.crm_event_add(k, sev, t, coalesce(r.from_status, '–') || ' → ' || coalesce(r.to_status, '–'), r.lead_email, null,
                               p_source, 'stage:' || r.id, coalesce(r.actor, 'sheet'), r.at);
end $$;

create or replace function public.crm_ev_desk(r public.desk_items, p_what text, p_source text default 'desk') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_what = 'hold' then
    perform public.crm_event_add('hold', 'alert', 'Hold: ' || r.client || ' · ' || r.title, r.detail, r.emails[1], r.link, p_source,
                                 'hold:' || r.id, coalesce(r.set_by, r.created_by), r.created_at);
  elsif p_what = 'lifted' then
    perform public.crm_event_add('hold', 'info', 'Hold lifted: ' || r.client || ' · ' || r.title, r.closed_note, r.emails[1], r.link, p_source,
                                 'hold:' || r.id || ':lifted', public.crm_actor(), coalesce(r.closed_at, now()));
  elsif p_what = 'founder_check' then        -- a piece of client work now waits on a founder
    perform public.crm_event_add('task', 'info', 'Waits on ' || coalesce(r.set_by, 'a founder') || ': ' || r.client || ' · ' || r.title,
                                 r.detail, r.emails[1], r.link, p_source, 'prod:' || r.id || ':founder_check:' || public.crm_ts(now()),
                                 coalesce(r.builder, r.created_by), now());
  end if;
end $$;

create or replace function public.crm_ev_task(r public.founder_tasks, p_source text default 'tasks') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_event_add('task', 'info', 'Task for ' || coalesce(r.who, 'either founder') || ': ' || r.title,
    concat_ws(' · ', r.detail, 'due ' || to_char(r.due_at at time zone 'Europe/Vilnius', 'Dy DD Mon HH24:MI')), r.lead_email, null,
    p_source, 'task:' || r.id, r.created_by, r.created_at);
end $$;

-- ---------- triggers ----------
create or replace function public.crm_tg_payment() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_payment(new); return null; end $$;
drop trigger if exists crm_event on public.payments;
create trigger crm_event after insert on public.payments for each row execute function public.crm_tg_payment();

create or replace function public.crm_tg_call() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then perform public.crm_ev_call(new, coalesce(new.status, '') = 'cancelled');
  elsif coalesce(new.status, '') = 'cancelled' and coalesce(old.status, '') <> 'cancelled' then perform public.crm_ev_call(new, true);
  end if;
  return null;
end $$;
drop trigger if exists crm_event on public.calls;
create trigger crm_event after insert or update of status on public.calls for each row execute function public.crm_tg_call();

-- reply_queue holds ONE row per lead (upsert on lead_email): a new reply from a known lead arrives as an UPDATE.
create or replace function public.crm_tg_reply() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and old.received_at is not distinct from new.received_at and old.kind is not distinct from new.kind then return null; end if;
  perform public.crm_ev_reply(new);
  return null;
end $$;
drop trigger if exists crm_event on public.reply_queue;
create trigger crm_event after insert or update of received_at, kind on public.reply_queue for each row execute function public.crm_tg_reply();

create or replace function public.crm_tg_interested() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_interested(new); return null; end $$;
drop trigger if exists crm_event on public.interested_leads;
create trigger crm_event after insert on public.interested_leads for each row execute function public.crm_tg_interested();

create or replace function public.crm_tg_sample() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_sample(new); return null; end $$;
drop trigger if exists crm_event on public.sample_requests;
create trigger crm_event after insert on public.sample_requests for each row execute function public.crm_tg_sample();

create or replace function public.crm_tg_stage() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_stage(new); return null; end $$;
drop trigger if exists crm_event on public.stage_log;
create trigger crm_event after insert on public.stage_log for each row execute function public.crm_tg_stage();

create or replace function public.crm_tg_desk() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind = 'hold' then
    if tg_op = 'INSERT' and new.status = 'open' then perform public.crm_ev_desk(new, 'hold');
    elsif tg_op = 'UPDATE' and old.status = 'open' and new.status = 'closed' then perform public.crm_ev_desk(new, 'lifted');
    end if;
  elsif new.kind = 'production' and new.status = 'open' and new.stage = 'founder_check'
        and (tg_op = 'INSERT' or old.stage is distinct from 'founder_check' or old.status is distinct from 'open') then
    perform public.crm_ev_desk(new, 'founder_check');
  end if;
  return null;
end $$;
drop trigger if exists crm_event on public.desk_items;
create trigger crm_event after insert or update of status, stage on public.desk_items for each row execute function public.crm_tg_desk();

create or replace function public.crm_tg_task() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_task(new); return null; end $$;
drop trigger if exists crm_event on public.founder_tasks;
create trigger crm_event after insert on public.founder_tasks for each row execute function public.crm_tg_task();

-- touches: the trigger lives in crm_touch2.sql (it reads the status / scheduled_at columns added there).

-- ---------- nobody calls the helpers over the API ----------
do $$
declare f text;
begin
  foreach f in array array[
    'public.crm_event_add(text,text,text,text,text,text,text,text,text,timestamptz)', 'public.crm_lead_label(text)',
    'public.crm_money(numeric)', 'public.crm_ts(timestamptz)', 'public.crm_actor()', 'public.crm_source()',
    'public.crm_ev_payment(public.payments,text)', 'public.crm_ev_call(public.calls,boolean,text)', 'public.crm_ev_reply(public.reply_queue,text)',
    'public.crm_ev_interested(public.interested_leads,text)', 'public.crm_ev_sample(public.sample_requests,text)',
    'public.crm_ev_stage(public.stage_log,text)', 'public.crm_ev_desk(public.desk_items,text,text)', 'public.crm_ev_task(public.founder_tasks,text)',
    'public.crm_tg_payment()', 'public.crm_tg_call()', 'public.crm_tg_reply()', 'public.crm_tg_interested()', 'public.crm_tg_sample()',
    'public.crm_tg_stage()', 'public.crm_tg_desk()', 'public.crm_tg_task()']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- ---------- live in the browser ----------
do $$
declare t text;
begin
  foreach t in array array['crm_events', 'crm_event_state'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- backfill: the last 7 days, so the bell is not empty on day one (source = 'backfill'; refs dedup re-runs) ----------
select public.crm_ev_payment(p, 'backfill') from public.payments p where p.paid_at > now() - interval '7 days' order by p.paid_at;
select public.crm_ev_call(c, coalesce(c.status, '') = 'cancelled', 'backfill') from public.calls c where coalesce(c.booked_at, c.start_at) > now() - interval '7 days';
select public.crm_ev_reply(r, 'backfill') from public.reply_queue r where r.received_at > now() - interval '7 days';
select public.crm_ev_interested(i, 'backfill') from public.interested_leads i where i.interest_changed_at > now() - interval '7 days';
select public.crm_ev_sample(s, 'backfill') from public.sample_requests s where s.created_at > now() - interval '7 days';
select public.crm_ev_stage(l, 'backfill') from public.stage_log l where l.at > now() - interval '7 days';
select public.crm_ev_desk(d, 'hold', 'backfill') from public.desk_items d where d.kind = 'hold' and d.status = 'open' and d.created_at > now() - interval '7 days';
select public.crm_ev_task(t, 'backfill') from public.founder_tasks t where t.created_at > now() - interval '7 days';
