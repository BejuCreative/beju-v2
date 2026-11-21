-- crm_touch2.sql (11-21): touchpoints + stages for the agents and the page (after crm_touch1.sql + crm_notify1.sql).
-- Additive only: two columns + a dedup index on touches, a founders' update right on touches, a touch event trigger,
-- one new column at the END of lead_timeline (status) and of lead_stage (last_contact_at), the new view lead_next_step,
-- api_keys.expires_at, an api_log index for the per-key rate limit. Every existing column keeps its name, type and order.
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_touch2.sql

-- 1) touches: planned / done / canceled, when a planned one is due, and no double logging of the same message.
alter table public.touches add column if not exists status text not null default 'done';
alter table public.touches add column if not exists scheduled_at timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'touches_status_check' and conrelid = 'public.touches'::regclass) then
    alter table public.touches add constraint touches_status_check check (status in ('planned', 'done', 'canceled'));
  end if;
end $$;
create unique index if not exists touches_lead_ref on public.touches (lower(lead_email), ref) where ref is not null;
create index if not exists touches_planned on public.touches (lower(lead_email), scheduled_at) where status = 'planned';
-- founders close or move a planned touch from the page (audit_log records who did it)
drop policy if exists "founders edit" on public.touches;
create policy "founders edit" on public.touches for update using (public.is_admin()) with check (public.is_admin());
grant update (status, scheduled_at, summary, next_step, next_at) on public.touches to authenticated;

-- 2) the bell: one event per logged touch
create or replace function public.crm_ev_touch(r public.touches, p_source text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_event_add('touch', 'info',
    case when r.status = 'planned' then 'Planned ' || r.kind || ': ' when r.status = 'canceled' then 'Canceled ' || r.kind || ': '
         else initcap(r.kind) || ' logged: ' end || public.crm_lead_label(r.lead_email),
    concat_ws(' · ', r.summary,
              'when ' || to_char(r.scheduled_at at time zone 'Europe/Vilnius', 'Dy DD Mon HH24:MI'),
              'next: ' || r.next_step || coalesce(' (' || to_char(r.next_at at time zone 'Europe/Vilnius', 'Dy DD Mon HH24:MI') || ')', '')),
    r.lead_email, case when r.ref ~ '^https?://' then r.ref end, coalesce(p_source, r.source, 'touch'), 'touch:' || r.id, r.actor, r.created_at);
end $$;
create or replace function public.crm_tg_touch() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_touch(new); return null; end $$;
drop trigger if exists crm_event on public.touches;
create trigger crm_event after insert on public.touches for each row execute function public.crm_tg_touch();
revoke all on function public.crm_ev_touch(public.touches, text) from public, anon, authenticated;
revoke all on function public.crm_tg_touch() from public, anon, authenticated;

-- 3) lead_timeline: same rows and columns as crm_touch1.sql + `status` at the end (planned = still ahead, canceled, done).
--    A planned touch sits at its scheduled time.
create or replace view public.lead_timeline with (security_invoker = on) as
  select lower(t.lead_email) as email, t.at, 'email'::text as kind, t.direction,
         coalesce(nullif(t.subject, ''), '(no subject)') || ' · ' || left(coalesce(t.snippet, ''), 160) as summary,
         t.inbox as actor, t.source, t.msg_id as ref, null::text as next_step, null::timestamptz as next_at, 'done'::text as status
    from public.threads t where t.lead_email is not null
  union all
  select lower(c.email), c.start_at, 'call', 'in', 'Call: ' || coalesce(c.title, '') || ' (' || coalesce(c.status, '') || ')',
         c.organizer, 'cal.com', c.uid, null, null,
         case when lower(coalesce(c.status, '')) = 'cancelled' then 'canceled' when c.start_at > now() then 'planned' else 'done' end
    from public.calls c where c.email is not null
  union all
  select lower(p.email), p.paid_at, 'payment', 'in',
         '$' || p.amount::text || ' ' || coalesce(p.package, p.description, '') || case when p.refunded then ' (refunded)' else '' end,
         'stripe', 'stripe', p.id, null, null, 'done'
    from public.payments p where p.email is not null
  union all
  select lower(s.lead_email), s.at, 'stage', 'internal', coalesce(s.from_status, '–') || ' → ' || coalesce(s.to_status, '–'),
         s.actor, 'crm', s.id::text, null, null, 'done'
    from public.stage_log s where s.lead_email is not null
  union all
  select lower(n.lead_email), n.created_at, 'note', 'internal', left(n.note, 240), n.actor, 'client_notes', n.id::text, null, null, 'done'
    from public.client_notes n where n.lead_email is not null
  union all
  select lower(pr.lead_email), pr.created_at, 'promise', 'out', pr.promise || ' [' || coalesce(pr.status, '') || ']',
         pr.created_by, 'crm', pr.id::text, null, pr.due_at,
         case pr.status when 'open' then 'planned' when 'void' then 'canceled' else 'done' end
    from public.promises pr where pr.lead_email is not null
  union all
  select lower(em), d.created_at, d.kind, 'internal', d.title || coalesce(' · ' || d.stage, '') || case when d.status = 'closed' then ' (closed)' else '' end,
         d.created_by, 'desk', d.id::text, null, null, 'done'
    from public.desk_items d, unnest(d.emails) em
  union all
  select lower(ce), dl.delivered_at::timestamptz, 'delivery', 'out', dl.title || coalesce(' · ' || dl.order_name, ''),
         'drive', 'drive', dl.id, null, null, 'done'
    from public.deliveries dl join public.clients cl on cl.id = dl.client_id, unnest(cl.emails) ce
  union all
  select lower(x.lead_email), case when x.status = 'planned' then coalesce(x.scheduled_at, x.next_at, x.at) else x.at end,
         x.kind, x.direction, x.summary, x.actor, coalesce(x.source, 'touch'), x.ref, x.next_step, x.next_at, x.status
    from public.touches x;
revoke all on public.lead_timeline from anon;
grant select on public.lead_timeline to authenticated;

-- 4) lead_next_step: ONE next step per lead. The earliest planned touch wins; else the pipeline's next action (Samples
--    sheet / crm.set_next); else the next step written on the lead's newest done touch.
create or replace view public.lead_next_step with (security_invoker = on) as
with planned as (
  select distinct on (lower(t.lead_email)) lower(t.lead_email) as email, t.kind || ': ' || t.summary as next_step,
         coalesce(t.scheduled_at, t.next_at) as next_at, t.id as touch_id, t.actor
    from public.touches t where t.status = 'planned'
   order by lower(t.lead_email), coalesce(t.scheduled_at, t.next_at) asc nulls last, t.id
),
pipe as (
  select lower(p.email) as email, p.next_action, p.next_action_at, p.owner from public.pipeline p
   where p.email is not null and nullif(trim(p.next_action), '') is not null
),
lastt as (
  select distinct on (lower(t.lead_email)) lower(t.lead_email) as email, t.next_step, t.next_at, t.id, t.actor
    from public.touches t where t.status = 'done'
   order by lower(t.lead_email), t.at desc, t.id desc
),
leads as (
  select email from planned union select email from pipe union select email from lastt where nullif(trim(next_step), '') is not null
)
select l.email,
       coalesce(pl.next_step, pp.next_action, lt.next_step) as next_step,
       case when pl.email is not null then pl.next_at when pp.email is not null then pp.next_action_at else lt.next_at end as next_at,
       case when pl.email is not null then 'touch:planned' when pp.email is not null then 'pipeline' else 'touch' end as source,
       case when pl.email is not null then pl.touch_id when pp.email is null then lt.id end as touch_id,
       case when pl.email is not null then pl.actor when pp.email is not null then pp.owner else lt.actor end as actor,
       coalesce(case when pl.email is not null then pl.next_at when pp.email is not null then pp.next_action_at else lt.next_at end < now(), false) as overdue
  from leads l
  left join planned pl on pl.email = l.email
  left join pipe pp on pp.email = l.email
  left join lastt lt on lt.email = l.email and nullif(trim(lt.next_step), '') is not null;
revoke all on public.lead_next_step from anon;
grant select on public.lead_next_step to authenticated;

-- 5) lead_stage: identical to crm_touch1.sql + last_contact_at at the end = the newest email / call / meeting / DM in
--    either direction that already happened (lead_timeline, status done).
create or replace view public.lead_stage with (security_invoker = on) as
with leads as (
  select lower(email) e from public.pipeline where email is not null
  union select lower(email) from public.interested_leads where email is not null
  union select lower(email) from public.payments where email is not null
  union select lower(email) from public.calls where email is not null
),
pay as (
  select lower(p.email) e, p.amount, p.paid_at, coalesce(p.refunded, false) refunded from public.payments p where p.email is not null
  union all
  select lower(ce), p.amount, p.paid_at, coalesce(p.refunded, false) from public.payments p join public.clients c on c.id = p.client_id, unnest(c.emails) ce
),
paid as (select e, sum(amount) filter (where not refunded) amt, max(paid_at) last_paid from pay group by e having sum(amount) filter (where not refunded) > 0),
offer as (select lower(lead_email) e, max(at) at from public.threads
          where direction = 'out' and body ~* '(buy\.stripe\.com|bejucreative\.digital/(plans|scope)/)' group by 1),
inbound as (select lower(lead_email) e, max(at) at from public.threads where direction = 'in' group by 1),
booked as (select lower(email) e, max(start_at) at from public.calls where coalesce(status, '') <> 'cancelled' group by 1),
opp as (select lower(email) e, max(value_usd) v from public.opportunities where email is not null and closed_at is null group by 1),
lc as (select email e, max(at) at from public.lead_timeline
        where kind in ('email', 'call', 'meeting', 'dm') and status = 'done' and at <= now() group by 1),
s as (
  select l.e as email, pl.name, pl.owner, pl.status, pl.fu_stage, pl.fu_day0, pl.next_action, pl.next_action_at,
    case
      when pd.e is not null or pl.status = 'WON'                                       then 'won'
      when pl.status = 'LOST' or pl.fu_stage = 'none'                                 then 'lost'
      when pl.fu_stage = 'parked'                                                     then 'parked'
      when pl.fu_stage = 'said_yes'                                                   then 'committed'
      when pl.fu_stage = 'asked_price' or o.e is not null                             then 'proposal'
      when pl.fu_stage in ('sample_sent','thinking') or pl.status in ('DELIVERED','HOT') or b.e is not null then 'engaged'
      else 'replied'
    end as stage,
    case
      when pd.e is not null then 'paid $' || pd.amt::text || ' (last ' || to_char(pd.last_paid at time zone 'Europe/Vilnius', 'YYYY-MM-DD') || ')'
      when pl.status = 'WON' then 'Samples status WON'
      when pl.status = 'LOST' then 'Samples status LOST'
      when pl.fu_stage = 'none' then 'follow-ups stopped (fu_stage none), no payment'
      when pl.fu_stage = 'parked' then 'cadence finished' || coalesce(': ' || left(pl.fu_note, 120), '')
      when pl.fu_stage = 'said_yes' then 'said yes, waiting for payment' || coalesce(': ' || left(pl.fu_note, 120), '')
      when pl.fu_stage = 'asked_price' then 'price sent, quiet' || coalesce(': ' || left(pl.fu_note, 120), '')
      when o.e is not null then 'offer in writing on ' || to_char(o.at at time zone 'Europe/Vilnius', 'YYYY-MM-DD')
      when b.e is not null then 'call booked for ' || to_char(b.at at time zone 'Europe/Vilnius', 'YYYY-MM-DD')
      when pl.fu_stage is not null or pl.status is not null then 'sample / hot: status ' || coalesce(pl.status, '') || coalesce(', fu ' || pl.fu_stage, '')
      else 'replied' || coalesce(' on ' || to_char(i.at at time zone 'Europe/Vilnius', 'YYYY-MM-DD'), '')
    end as evidence,
    case
      when pd.e is not null then pd.last_paid
      when pl.fu_stage in ('parked','said_yes','asked_price','sample_sent','thinking') then pl.fu_day0
      when o.e is not null then o.at
      when b.e is not null then b.at
      else coalesce(i.at, pl.last_reply_at, pl.updated_at)
    end as stage_since,
    op.v as opp_value
  from leads l
  left join public.pipeline pl on lower(pl.email) = l.e
  left join paid pd on pd.e = l.e
  left join offer o on o.e = l.e
  left join inbound i on i.e = l.e
  left join booked b on b.e = l.e
  left join opp op on op.e = l.e
)
select s.*, ds.ord, ds.is_open, ds.probability,
       coalesce(s.opp_value, ds.default_value_usd) as deal_value_usd,
       floor(extract(epoch from now() - s.stage_since) / 86400)::int as days_in_stage,
       (ds.is_open and ds.max_quiet_days is not null and s.stage_since < now() - make_interval(days => ds.max_quiet_days)) as overdue,
       lc.at as last_contact_at
from s join public.deal_stages ds on ds.stage = s.stage
left join lc on lc.e = s.email;
revoke all on public.lead_stage from anon;
grant select on public.lead_stage to authenticated;

-- 6) crm-api: keys can expire; per-key rate limit counts api_log rows of the last 60 s.
alter table public.api_keys add column if not exists expires_at timestamptz;
create index if not exists api_log_key_at on public.api_log (key_name, at desc);
