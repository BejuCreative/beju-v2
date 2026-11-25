-- crm_backend_1122.sql (Benas's Claude, 2026-11-22). Three backend pieces for the CRM; the screens are Simas's side.
--   A. Every send updates the CRM: send_cadence (view) + lead_send_state (table) + send_sync() every 5 min.
--   B. client_delivery_tracker (view): one row per order we still owe work on.
--   C. high_intent (view): leads with buying signals, scored, for "Big deals & high intent".
-- Needs (all live): crm_tasks_live1/2.sql (reply_wait, reply_is_noise), crm_api_pack1.sql (reply_wait_read,
-- sync_status.max_age_min), crm_leadflags1.sql, crm_orders1/3.sql, crm_ops7.sql (fu_state), form_leads_v2.
-- Re-run safe. Two LIVE objects are re-created with the same result (proved by tests, see the PR): reply_is_noise()
-- and offer_followups_due. Everything else is new.
-- Rollback: select cron.unschedule('send-sync'); drop view high_intent, client_delivery_tracker; re-run the
-- offer_followups_due block of crm_leadflags1.sql and the reply_is_noise block of crm_tasks_live1.sql; drop view
-- send_cadence; drop function send_sync(boolean), reply_is_hard_pass(text), email_is_offer(text), email_is_delivery(text);
-- drop table lead_send_state; delete from sync_status where name = 'send_sync';

-- ============================================================ 0. classifiers, one definition each

-- Our email names a price or links a plan / scope / payment page. Moved here unchanged from offer_followups_due
-- (crm_leadflags1.sql), which now calls it.
create or replace function public.email_is_offer(body text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(body ~* '(buy\.stripe\.com|bejucreative\.digital/(plans|scope)/)' or body ~* '\$\s?\d{2,}|\m\d{2,5} ?usd\M', false)
$$;

-- Our email hands over work: it carries a Drive link (samples and paid deliveries both do).
create or replace function public.email_is_delivery(body text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(body ~* 'drive\.google\.com/', false)
$$;

-- The lead said no (crm.js HARD_PASS). Moved here unchanged from reply_is_noise(), which now calls it.
create or replace function public.reply_is_hard_pass(t text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select public.reply_own_words(t) ~* '\y(?:going to|gonna|will|''ll|have to|must|i|we)\s+pass\y(?!\s+(?:this|it|that|them|your|you|the|along|on to|on your|on the))|\ypass(?:ing)? on (?:this|it|that|the offer|your offer)\y|\yno,?\s+thanks?\y|\yno thank you\y|\ynot interested\y|\ynot for (?:us|me)\y|\yplease (?:don''?t|do not) (?:follow up|contact|email|reach out|send)|^\W*(?:stop|unsubscribe|remove me)\y'
$$;

-- Same result as crm_tasks_live1.sql; only the hard-pass regex moved out (above).
create or replace function public.reply_is_noise(t text) returns boolean
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  w text := public.reply_own_words(t);
  auto_tx constant text := 'out of (the )?office|\yOOO\y|on (vacation|holiday|leave|maternity)|auto(matic)?[- ]?reply|thank(s| you)( so much| very much)? for (your (email|message|e-mail|inquiry|enquiry|note)|reaching|getting|emailing|contacting)|your (message|email) has been (received|forwarded)|you will receive a (response|reply)|vielen dank f|(reply|respond|get back)[^.]{0,40}(upon|on|after) my return|away at a conference|reply above this line|your request (\(#?\d+\) )?has been received|we strive to respond within|limited access to (my )?e-?mails?|for (the )?fastest (assistance|response)|we (aim to )?(respond|reply) to (all )?e-?mails? within|in the meantime, here are|view (this email )?in (your )?browser|unsubscribe';
  auto_more constant text := '\y(we(''ve)?|i(''ve)?|team has) received your (message|e-?mail|inquiry|enquiry|note)\y|\y(has|have) landed (safe|safely)\y|\ymy working hours\y|\yonly check (this|my) (e-?mail|inbox)\y|\ythanks? (so much )?for writing in\y|\yyour (request|ticket)\y[^.]{0,30}\yhas been received\y';
  yes_tx constant text := '\y(yes|yeah|sure|interested|go ahead|send it|please do|sounds good|let''?s do|i''?d (like|love|be happy)|take you up on)\y';
  human_tx constant text := 'sorry for the (late|delayed|slow) (reply|response)|\yi was (out|away|travell?ing)\y|\y(adding|looping in|cc''?ing|copying in)\y|\yi''?ve (now )?(reviewed|watched|looked)|\y(aren''?t|are not|am not|i''?m not|not) (currently )?(looking for|interested)|\yno,? thank(s| you)\y|\y(just|i''?ve|we''?ve|i|we) (just )?paid\y|looking forward to working (together|with)';
begin
  if public.reply_is_hard_pass(t) then return true; end if;
  if w ~* '\yautomated (e-?mail |email )?(response|reply|message)\y' then return true; end if;
  return (w ~* auto_tx or w ~* auto_more) and not (w ~* yes_tx) and not (w ~* human_tx);
end $$;

-- ============================================================ A. every send updates the CRM

-- send_cadence: one row per lead we have emailed (threads), always current. What the thread says comes next:
--   our offer / price email  -> FU1 if no reply, 2 days later
--   FU1 sent                 -> FU2 if no reply, 3 days after FU1
--   FU2 sent                 -> park, re-engage 30 days after our last email (max two follow-ups)
--   a delivery (Drive link)  -> the same ladder, counted from the delivery (only when no offer went since their last message)
--   the lead wrote           -> the pending follow-up is gone (anchors count from their last message); a real waiting
--                               reply shows as 'Reply to the lead' (reply_tasks_sync makes the task)
--   lost / on hold / snoozed -> blocked: no next step is ever scheduled
-- Leads on the sample cadence (fu_state active) keep that cadence's count and due date: one source per lead, the same
-- rule as offer_followups_due.
--   basis   cadence (fu_state) / offer / delivery / null
--   state   followup / reply / parked / blocked / none
create or replace view public.send_cadence with (security_invoker = on) as
with fu as materialized (       -- materialized: each of these is worked out once, never once per lead
  select email, state, fu_stage, touches_done, touches_total, due_at, reengage_at from public.fu_state
), rw as materialized (
  select lead_email, received_at from public.reply_wait_read()
), last_in as (
  select lower(lead_email) e, max(at) at from public.threads where direction = 'in' group by 1
), outs as materialized (
  select lower(t.lead_email) e, t.at, t.inbox, li.at last_in,
         public.email_is_offer(t.body) is_offer, public.email_is_delivery(t.body) is_delivery
    from public.threads t left join last_in li on li.e = lower(t.lead_email)
   where t.direction = 'out' and t.lead_email is not null
), anchor as (
  -- the FIRST offer / delivery after their last message, so a follow-up that repeats the price never restarts the count
  select e, max(last_in) last_in, max(at) last_out, (array_agg(inbox order by at desc nulls last))[1] last_inbox,
         min(at) filter (where is_offer and at > coalesce(last_in, '-infinity'::timestamptz)) offer_at,
         min(at) filter (where is_delivery and at > coalesce(last_in, '-infinity'::timestamptz)) delivery_at
    from outs group by e
), counted as (
  select a.*,
         (select count(*) from outs o where o.e = a.e and o.at > a.offer_at)::int offer_fus,
         (select count(*) from outs o where o.e = a.e and o.at > a.delivery_at)::int delivery_fus
    from anchor a
), lead as (
  select c.*, p.name, p.owner p_owner, (p.email is not null) in_pipeline,
         fs.state fu_state, fs.fu_stage, fs.touches_done, fs.touches_total, fs.due_at fu_due, fs.reengage_at,
         w.received_at reply_at,
         case when c.offer_fus = 0 then c.offer_at + interval '2 days' else c.last_out + interval '3 days' end offer_due_at,
         case when f.lost_reason is not null or upper(coalesce(p.status, '')) = 'LOST' or p.fu_stage = 'none' then 'lost'
              when upper(coalesce(p.status, '')) = 'HOLD'
                or exists (select 1 from public.desk_items h, unnest(h.emails) x
                            where h.kind = 'hold' and h.status = 'open' and lower(x) = c.e) then 'hold'
              when f.snoozed_until > now() then 'snoozed' end blocked_by,
         case when fs.state = 'active' then 'cadence'
              when c.offer_at is not null then 'offer'
              when c.delivery_at is not null then 'delivery'
              when fs.state = 'finished' then 'cadence' end basis
    from counted c
    left join public.pipeline p on p.email = c.e
    left join public.lead_flags f on f.email = c.e
    left join fu fs on fs.email = c.e
    left join rw w on w.lead_email = c.e
), st as (
  select l.*,
         case l.basis when 'cadence' then l.touches_done when 'offer' then l.offer_fus when 'delivery' then l.delivery_fus end fus,
         case when l.blocked_by is not null then 'blocked'
              when l.reply_at is not null then 'reply'
              when l.basis = 'cadence' then case when l.fu_state = 'active' then 'followup' else 'parked' end
              when l.basis = 'offer' then case when l.offer_fus < 2 then 'followup' else 'parked' end
              when l.basis = 'delivery' then case when l.delivery_fus < 2 then 'followup' else 'parked' end
              else 'none' end state
    from lead l
)
select s.e email, s.name,
       case when s.p_owner in ('Simas', 'Benas') then s.p_owner else public.inbox_owner(s.last_inbox) end owner,
       s.in_pipeline, s.last_out last_out_at, s.last_in last_in_at, greatest(s.last_out, s.last_in) last_touch_at,
       s.basis, s.fus followups_done, s.state, s.blocked_by,
       case s.state
         when 'reply' then 'Reply to the lead'
         when 'parked' then 'Park: follow-ups sent, re-engage later'
         when 'followup' then case when s.basis = 'cadence' and s.fu_stage = 'parked' then 'Re-engage once (parked)'
                                   when s.basis = 'cadence' then format('FU%s of %s if no reply (%s)', s.fus + 1, s.touches_total, replace(s.fu_stage, '_', ' '))
                                   else format('FU%s if no reply', s.fus + 1) end
       end next_step,
       case s.state
         when 'reply' then s.reply_at
         when 'parked' then case when s.basis = 'cadence' then s.reengage_at else s.last_out + interval '30 days' end
         when 'followup' then case s.basis when 'cadence' then s.fu_due when 'offer' then s.offer_due_at
                                   else case when s.delivery_fus = 0 then s.delivery_at + interval '2 days' else s.last_out + interval '3 days' end end
       end next_due,
       s.offer_at, s.offer_fus offer_followups, case when s.offer_at is not null then s.offer_due_at end offer_due_at
  from st s;
revoke all on public.send_cadence from anon, authenticated;
grant select on public.send_cadence to authenticated;      -- founders only: RLS on every table below is is_admin()

-- offer_followups_due: same columns, same rows as crm_leadflags1.sql. Its offer / follow-up count now comes from
-- send_cadence, so the reminder tasks and the lead's send state can never disagree.
create or replace view public.offer_followups_due with (security_invoker = on) as
with due as materialized (
  select c.email e, c.offer_at, c.offer_followups fus, c.last_out_at last_out, c.offer_due_at due_at
    from public.send_cadence c where c.offer_at is not null and c.offer_followups < 2
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

-- lead_send_state: the stored copy of send_cadence, one row per lead. A table so the screens can read it cheaply and
-- subscribe to it; updated_at moves only when something in the row changed. Written by send_sync() only.
create table if not exists public.lead_send_state (
  email          text primary key,
  name           text,
  owner          text,
  in_pipeline    boolean not null default false,
  last_out_at    timestamptz,
  last_in_at     timestamptz,
  last_touch_at  timestamptz,
  basis          text,
  followups_done int,
  state          text not null,
  blocked_by     text,
  next_step      text,
  next_due       timestamptz,
  updated_at     timestamptz not null default now()
);
alter table public.lead_send_state enable row level security;
drop policy if exists "founders read" on public.lead_send_state;
create policy "founders read" on public.lead_send_state for select using (public.is_admin());
revoke all on public.lead_send_state from anon, authenticated;
grant select on public.lead_send_state to authenticated;   -- reads only; writes: send_sync() (security definer)

alter table public.sync_status add column if not exists max_age_min int;   -- already live (crm_api_pack1.sql)

-- send_sync(): copies send_cadence into lead_send_state (changed rows only) and writes sync_status 'send_sync'.
-- p_write_pipeline: also keep pipeline.next_action / next_action_at in step for leads with a pipeline row. OFF by
-- default: today ops-sync copies the Samples sheet over pipeline.next_action every 10 minutes, so writing it here
-- would flip it back and forth (and fill audit_log). Turn it on when the sheet stops being the master:
--   select cron.unschedule('send-sync'); select cron.schedule('send-sync', '1-59/5 * * * *', $$select public.send_sync(true)$$);
-- With it on, a next action is replaced only when it is empty, was written here (ends with ' (auto)'), or is dated at
-- or before our last email (stale). A hand-written next action with a later date, or with no date, is never touched.
create or replace function public.send_sync(p_write_pipeline boolean default false) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; d int := 0; p int := 0;
begin
  -- one statement, so send_cadence is worked out once and the upsert and the clean-up see the same rows
  with c as materialized (
    select distinct on (email) email, name, owner, in_pipeline, last_out_at, last_in_at, last_touch_at, basis, followups_done,
           state, blocked_by, next_step, next_due
      from public.send_cadence order by email
  ), up as (
    insert into public.lead_send_state as s (email, name, owner, in_pipeline, last_out_at, last_in_at, last_touch_at, basis,
                                             followups_done, state, blocked_by, next_step, next_due)
    select * from c
    on conflict (email) do update
       set name = excluded.name, owner = excluded.owner, in_pipeline = excluded.in_pipeline, last_out_at = excluded.last_out_at,
           last_in_at = excluded.last_in_at, last_touch_at = excluded.last_touch_at, basis = excluded.basis,
           followups_done = excluded.followups_done, state = excluded.state, blocked_by = excluded.blocked_by,
           next_step = excluded.next_step, next_due = excluded.next_due, updated_at = now()
     where (s.name, s.owner, s.in_pipeline, s.last_out_at, s.last_in_at, s.last_touch_at, s.basis, s.followups_done, s.state,
            s.blocked_by, s.next_step, s.next_due)
           is distinct from
           (excluded.name, excluded.owner, excluded.in_pipeline, excluded.last_out_at, excluded.last_in_at, excluded.last_touch_at,
            excluded.basis, excluded.followups_done, excluded.state, excluded.blocked_by, excluded.next_step, excluded.next_due)
    returning 1
  ), del as (
    delete from public.lead_send_state s where not exists (select 1 from c where c.email = s.email) returning 1
  )
  select (select count(*) from up), (select count(*) from del) into n, d;

  if p_write_pipeline then
    perform set_config('beju.actor', 'send-sync', true);       -- audit_log shows who wrote it
    update public.pipeline pl
       set next_action = s.next_step || ' (auto)', next_action_at = s.next_due
      from public.lead_send_state s
     where pl.email = s.email
       and (   (s.next_step is not null
                and (coalesce(pl.next_action, '') = '' or pl.next_action like '% (auto)' or pl.next_action_at <= s.last_out_at))
            or (s.next_step is null and pl.next_action like '% (auto)'))
       and (pl.next_action, pl.next_action_at) is distinct from (s.next_step || ' (auto)', s.next_due);
    get diagnostics p = row_count;
  end if;

  insert into public.sync_status (name, ran_at, ok, detail, max_age_min)
  values ('send_sync', now(), true, format('%s lead(s) changed, %s removed%s', n, d,
          case when p_write_pipeline then format(', %s pipeline next action(s)', p) else '' end), 12)
  on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  return n;
end $$;
revoke execute on function public.send_sync(boolean) from public, anon, authenticated;

select cron.unschedule('send-sync') where exists (select 1 from cron.job where jobname = 'send-sync');
select cron.schedule('send-sync', '1-59/5 * * * *', $$select public.send_sync()$$);

-- ============================================================ B. client delivery tracker

-- One row per order we still owe work on: open or paused orders, plus any order with a change request waiting.
--   promised / delivered   order_progress (orders + order_items: files in the client's order folder)
--   revisions_open         Shorts where the client asked for a change and no newer version is in the folder yet
--   next_due               the earliest of: the client's next open promise, the end of the order's 30 days (while
--                          Shorts are left), the oldest open change request + 24 hours
--   posting_status         'n of m posted' once a posted Short is on record, else null (not known)
--   status                 waiting on client  the order is paused
--                          overdue            next_due has passed, or the order is behind pace (order_problems rule)
--                          due soon           next_due within 3 days, or a change request is open
--                          on track           everything else
-- Promises are kept per client, not per order: a client with two open orders shows the same promise on both rows.
create or replace view public.client_delivery_tracker with (security_invoker = on) as
with prom as (
  select c.id client_id, count(*)::int open_promises, min(p.due_at) next_promise_due
    from public.clients c join public.promises p
      on lower(p.lead_email) in (select lower(x) from unnest(c.emails) x)
   where p.status = 'open' group by c.id
), rev as (
  select order_id, min(revision_asked_at) oldest_at from public.order_items where status = 'revision_requested' group by 1
), o as (
  select p.*, coalesce(pr.open_promises, 0) open_promises, pr.next_promise_due,
         least(pr.next_promise_due,
               case when p.left_to_deliver > 0 then p.period_end end,
               rv.oldest_at + interval '24 hours') next_due,
         exists (select 1 from public.desk_items h, public.clients c
                  where c.id = p.client_id and h.kind = 'hold' and h.status = 'open' and h.emails && c.emails) on_hold
    from public.order_progress p
    left join prom pr on pr.client_id = p.client_id
    left join rev rv on rv.order_id = p.id
   where p.status in ('open', 'paused') or p.in_revision > 0
)
select o.id order_id, o.client_id, o.client, o.kind,
       case o.kind when 'monthly' then format('Monthly %s Shorts', coalesce(o.bought::text, '?'))
                   when 'pack' then format('Pack of %s Shorts', coalesce(o.bought::text, '?'))
                   when 'long' then format('%s long videos', coalesce(o.bought::text, '?'))
                   when 'referral' then format('Referral: %s free Shorts', coalesce(o.bought::text, '?'))
                   else initcap(o.kind) || coalesce(' (' || o.bought || ')', '') end plan,
       o.status order_status, o.bought promised, o.delivered, o.left_to_deliver, o.in_revision revisions_open,
       o.last_delivery_at, o.opened_at, o.period_end, o.expected_by_now, o.open_promises, o.next_due,
       o.posted, case when o.posted > 0 then format('%s of %s posted', o.posted, o.delivered) end posting_status,
       o.on_hold, o.folder,
       case when o.status = 'paused' then 'waiting on client'
            when o.next_due < now() or (o.status = 'open' and o.delivered + 2 < o.expected_by_now) then 'overdue'
            when o.next_due < now() + interval '3 days' or o.in_revision > 0 then 'due soon'
            else 'on track' end status
  from o
 order by case when o.status = 'paused' then 3 when o.next_due < now() then 0 else 1 end, o.next_due nulls last, o.opened_at;
revoke all on public.client_delivery_tracker from anon, authenticated;
grant select on public.client_delivery_tracker to authenticated;   -- founders only, through the base tables' RLS

-- ============================================================ C. high intent

-- Leads (not paying clients) with a buying signal, one row per lead, strongest first.
--   asked_price (40)       pipeline fu_stage asked_price, or their own words in the last 30 days ask what it costs
--   posts_daily (30)       the brief form says they post daily / 5+ a week (form_leads_v2 tier 'daily')
--   systems_interest (25)  their own words in the last 30 days mention a funnel, email list, lead magnet, landing or
--                          sales page, their own website, ads, scaling, or growing / hiring a team. A bare "team" is
--                          not counted: on live replies it was always "I already have a team" (an objection)
--   big_50k (20)           came in through a 50k+ campaign, or a tracked account of theirs has 50k+ followers
--   replied_14d (10)       a real reply in the last 14 days (not an auto-reply, not a no). Adds to the score; a lead
--                          needs at least one of the four signals above to be listed.
-- Left out: open desk hold or sheet status HOLD, lost (lead_flags reason, status LOST, follow-ups stopped), closed
-- (WON / DONE), blocklisted, paid before or on a clients row, and leads whose latest message is a hard pass.
-- next_step / next_due / last_touch_at come from send_cadence (part A).
create or replace view public.high_intent with (security_invoker = on) as
with inb as (
  select lower(t.lead_email) e, t.at, t.inbox, coalesce(t.snippet, t.body, '') snip, coalesce(t.body, t.snippet, '') txt
    from public.threads t where t.direction = 'in' and t.lead_email is not null and t.at is not null
  union all
  select lower(r.lead_email), r.received_at, r.inbox, coalesce(r.snippet, ''), coalesce(r.snippet, '')
    from public.reply_queue r where r.received_at is not null
), words as materialized (
  select i.e, i.at, i.inbox, public.reply_own_words(i.txt) w, public.reply_is_noise(i.snip) noise, public.reply_is_hard_pass(i.snip) hard_pass
    from inb i
), marked as (
  select w.*,
         not w.noise and w.at > now() - interval '30 days'
           and w.w ~* '\y(pric(e|es|ing)|costs?|rates?|fees?|how much (is|are|do|does|would|will|for|it|you|per))\y|(?<!free of )\ycharge\y' price,
         not w.noise and w.at > now() - interval '30 days'
           and w.w ~* '\y(funnels?|(e-?mail|mailing) list|lead magnets?|(landing|sales) pages?|vsl|ads|advertising|ad (spend|campaigns?)|scal(e|ing)|(grow|build|hire|hiring) (my|our|a|the) team)\y|\y(my|our|a|new) (new )?website\y(?!\s*[:(|]|\s+(https?|www|\d))' systems
    from words w
), latest as (
  select distinct on (e) e, at, inbox, hard_pass from marked order by e, at desc
), sig as (
  select e, bool_or(price) price, bool_or(systems) systems,
         bool_or(not noise and at > now() - interval '14 days') replied_14d,
         max(at) filter (where not noise) last_reply_at,
         (array_agg(left(trim(w), 240) order by at desc) filter (where price or systems))[1] their_words
    from marked group by e
), brief as (
  select lower(fl.lead_email) e, max(fl.name) name, max(fl.post_freq) post_freq
    from public.form_leads_v2 fl
   where fl.tier = 'daily' and fl.stage not in ('paid', 'lost') and not fl.on_hold group by 1
), big as (
  select lower(i.email) e from public.interested_leads i where i.campaign ~* '50k\+'
  union
  select lower(a.email) from public.client_accounts a where a.followers >= 50000
), sc as materialized (
  select email, last_touch_at, next_step, next_due from public.send_cadence
), cand as (
  select e from brief union select e from big
  union select lower(p.email) from public.pipeline p where p.fu_stage = 'asked_price'
  union select e from sig where price or systems
), f as (
  select c.e, p.status, p.fu_stage, p.campaign p_campaign, i.campaign i_campaign, lf.snoozed_until,
         coalesce(p.name, b.name, nullif(concat_ws(' · ', nullif(trim(i.first_name), ''), nullif(trim(i.company), '')), '')) name,
         case when p.owner in ('Simas', 'Benas') then p.owner else public.inbox_owner(coalesce(p.inbox, i.inbox, l.inbox)) end owner,
         coalesce(s.price, false) or coalesce(p.fu_stage = 'asked_price', false) asked_price,
         b.e is not null posts_daily, b.post_freq,
         coalesce(s.systems, false) systems_interest,
         exists (select 1 from big g where g.e = c.e) big_50k,
         coalesce(s.replied_14d, false) replied_14d,
         s.last_reply_at, s.their_words,
         coalesce(sc.last_touch_at, l.at) last_touch_at, sc.next_step, sc.next_due
    from cand c
    left join public.pipeline p on p.email = c.e
    left join public.interested_leads i on i.email = c.e
    left join public.lead_flags lf on lf.email = c.e
    left join brief b on b.e = c.e
    left join sig s on s.e = c.e
    left join latest l on l.e = c.e
    left join sc on sc.email = c.e
   where c.e is not null
     and lf.lost_reason is null
     and upper(coalesce(p.status, '')) not in ('HOLD', 'LOST', 'WON', 'DONE') and coalesce(p.fu_stage, '') <> 'none' and coalesce(p.paid, '') = ''
     and not coalesce(l.hard_pass, false)
     and not exists (select 1 from public.desk_items h, unnest(h.emails) x where h.kind = 'hold' and h.status = 'open' and lower(x) = c.e)
     and not exists (select 1 from public.reply_queue r where lower(r.lead_email) = c.e and r.blocklisted)
     and not exists (select 1 from public.payments pay where lower(pay.email) = c.e and not pay.refunded)
     and not exists (select 1 from public.clients k, unnest(k.emails) x where lower(x) = c.e)
)
select f.e email, f.name, f.owner,
       (case when f.asked_price then 40 else 0 end + case when f.posts_daily then 30 else 0 end
        + case when f.systems_interest then 25 else 0 end + case when f.big_50k then 20 else 0 end
        + case when f.replied_14d then 10 else 0 end) score,
       case when f.asked_price then 'asked price' when f.posts_daily then 'posts daily (brief form)'
            when f.systems_interest then 'systems interest' else '50k+ audience' end strongest,
       array_remove(array[case when f.asked_price then 'asked_price' end, case when f.posts_daily then 'posts_daily' end,
                          case when f.systems_interest then 'systems_interest' end, case when f.big_50k then 'big_50k' end,
                          case when f.replied_14d then 'replied_14d' end], null) flags,
       f.asked_price, f.posts_daily, f.systems_interest, f.big_50k, f.replied_14d,
       f.post_freq, f.their_words, f.last_reply_at, f.last_touch_at, f.next_step, f.next_due,
       f.status pipeline_status, f.fu_stage, coalesce(f.p_campaign, f.i_campaign) campaign, f.snoozed_until
  from f
 order by 4 desc, f.last_reply_at desc nulls last, f.e;
revoke all on public.high_intent from anon, authenticated;
grant select on public.high_intent to authenticated;       -- founders only, through the base tables' RLS
