-- crm_touch3.sql (11-21, fixes from the UI agent's real-data test). Same views, same columns in the same order.
-- 1) lead_stage: stage_since is never in the future, so days_in_stage is never below 0 and "overdue" stays right.
--    Parked leads keep their FUTURE re-engage date in fu_day0 (crm.roll), and "thinking" leads the date they named;
--    parked now counts from the last status change (pipeline.stage_changed_at), the rest are capped at now().
-- 2) lead_next_step: a founder's touch is no longer hidden behind an older pipeline next action. Order:
--    a) the soonest OPEN planned touch;  b) else the next step on the lead's newest done touch, when that touch was written
--    after the pipeline's next action was last written (audit_log; a next action with no audit row counts as older);
--    c) else the pipeline's next action;  d) else the newest touch's next step.
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_touch3.sql

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
    least(case
      when pd.e is not null then pd.last_paid
      when pl.fu_stage = 'parked' then least(pl.stage_changed_at, pl.fu_day0)   -- fu_day0 = the FUTURE re-engage date here
      when pl.fu_stage in ('said_yes','asked_price','sample_sent','thinking') then pl.fu_day0
      when o.e is not null then o.at
      when b.e is not null then b.at
      else coalesce(i.at, pl.last_reply_at, pl.updated_at)
    end, now()) as stage_since,                                                  -- never in the future: days_in_stage >= 0
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

create or replace view public.lead_next_step with (security_invoker = on) as
with planned as (
  select distinct on (lower(t.lead_email)) lower(t.lead_email) as email, t.kind || ': ' || t.summary as next_step,
         coalesce(t.scheduled_at, t.next_at) as next_at, t.id as touch_id, t.actor
    from public.touches t where t.status = 'planned'
   order by lower(t.lead_email), coalesce(t.scheduled_at, t.next_at) asc nulls last, t.created_at desc, t.id desc
),
pipe as (
  select lower(p.email) as email, p.next_action, p.next_action_at, p.owner,
         (select max(a.at) from public.audit_log a
           where a.table_name = 'pipeline' and a.row_key = p.email and a.changed ? 'next_action') as written_at
    from public.pipeline p
   where p.email is not null and nullif(trim(p.next_action), '') is not null
),
tnext as (
  select x.* from (
    select distinct on (lower(t.lead_email)) lower(t.lead_email) as email, t.next_step, t.next_at, t.id, t.actor, t.created_at
      from public.touches t where t.status = 'done'
     order by lower(t.lead_email), t.at desc, t.id desc) x
   where nullif(trim(x.next_step), '') is not null
),
leads as (select email from planned union select email from pipe union select email from tnext),
pick as (
  select l.email, pl.email as pl_e, pp.email as pp_e, tn.email as tn_e, pl.next_step as pl_step, pl.next_at as pl_at, pl.touch_id as pl_id,
         pl.actor as pl_actor, pp.next_action, pp.next_action_at, pp.owner, tn.next_step as tn_step, tn.next_at as tn_at, tn.id as tn_id,
         tn.actor as tn_actor,
         case when pl.email is not null then 'touch:planned'
              when tn.email is not null and (pp.email is null or pp.written_at is null or tn.created_at > pp.written_at) then 'touch'
              else 'pipeline' end as src
    from leads l
    left join planned pl on pl.email = l.email
    left join pipe pp on pp.email = l.email
    left join tnext tn on tn.email = l.email
)
select email,
       case src when 'touch:planned' then pl_step when 'touch' then tn_step else next_action end as next_step,
       case src when 'touch:planned' then pl_at when 'touch' then tn_at else next_action_at end as next_at,
       src as source,
       case src when 'touch:planned' then pl_id when 'touch' then tn_id end as touch_id,
       case src when 'touch:planned' then pl_actor when 'touch' then tn_actor else owner end as actor,
       coalesce((case src when 'touch:planned' then pl_at when 'touch' then tn_at else next_action_at end) < now(), false) as overdue
  from pick;
revoke all on public.lead_next_step from anon;
grant select on public.lead_next_step to authenticated;
