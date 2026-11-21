-- 11-21 (SIMAS): "Log every touchpoint: record calls, emails, meetings, and next steps right after they happen so context is
-- never lost." + "Work out of clear pipeline stages: move deals forward only when specific exit criteria are met, keeping
-- forecasts realistic." Additive: one new table, one reference table, three views. Nothing existing changes.

-- 1) touches: what the CRM can't see on its own (call/meeting outcomes, Gmail, DMs, Looms, founder decisions), with the next step.
create table if not exists public.touches (
  id         bigint generated always as identity primary key,
  lead_email text not null,
  kind       text not null check (kind in ('call','meeting','email','dm','loom','delivery','decision','note','other')),
  direction  text not null default 'out' check (direction in ('in','out','internal')),
  at         timestamptz not null default now(),
  summary    text not null,
  next_step  text,
  next_at    timestamptz,
  actor      text not null,
  source     text,                 -- gmail, fathom, whatsapp, slack, instagram, loom…
  ref        text,                 -- message id or link
  created_at timestamptz not null default now()
);
create index if not exists touches_lead_at on public.touches (lower(lead_email), at desc);
alter table public.touches enable row level security;
revoke all on public.touches from anon, authenticated;
drop policy if exists "founders read" on public.touches;
drop policy if exists "founders add" on public.touches;
create policy "founders read" on public.touches for select using (public.is_admin());
create policy "founders add"  on public.touches for insert with check (public.is_admin());
grant select, insert on public.touches to authenticated;

-- 2) lead_timeline: every touchpoint of a lead, from every source, newest first (read it with ?email=eq.<lead>&order=at.desc).
create or replace view public.lead_timeline with (security_invoker = on) as
  select lower(t.lead_email) as email, t.at, 'email'::text as kind, t.direction,
         coalesce(nullif(t.subject, ''), '(no subject)') || ' · ' || left(coalesce(t.snippet, ''), 160) as summary,
         t.inbox as actor, t.source, t.msg_id as ref, null::text as next_step, null::timestamptz as next_at
    from public.threads t where t.lead_email is not null
  union all
  select lower(c.email), c.start_at, 'call', 'in', 'Call: ' || coalesce(c.title, '') || ' (' || coalesce(c.status, '') || ')',
         c.organizer, 'cal.com', c.uid, null, null
    from public.calls c where c.email is not null
  union all
  select lower(p.email), p.paid_at, 'payment', 'in',
         '$' || p.amount::text || ' ' || coalesce(p.package, p.description, '') || case when p.refunded then ' (refunded)' else '' end,
         'stripe', 'stripe', p.id, null, null
    from public.payments p where p.email is not null
  union all
  select lower(s.lead_email), s.at, 'stage', 'internal', coalesce(s.from_status, '–') || ' → ' || coalesce(s.to_status, '–'),
         s.actor, 'crm', s.id::text, null, null
    from public.stage_log s where s.lead_email is not null
  union all
  select lower(n.lead_email), n.created_at, 'note', 'internal', left(n.note, 240), n.actor, 'client_notes', n.id::text, null, null
    from public.client_notes n where n.lead_email is not null
  union all
  select lower(pr.lead_email), pr.created_at, 'promise', 'out', pr.promise || ' [' || coalesce(pr.status, '') || ']',
         pr.created_by, 'crm', pr.id::text, null, pr.due_at
    from public.promises pr where pr.lead_email is not null
  union all
  select lower(em), d.created_at, d.kind, 'internal', d.title || coalesce(' · ' || d.stage, '') || case when d.status = 'closed' then ' (closed)' else '' end,
         d.created_by, 'desk', d.id::text, null, null
    from public.desk_items d, unnest(d.emails) em
  union all
  select lower(ce), dl.delivered_at::timestamptz, 'delivery', 'out', dl.title || coalesce(' · ' || dl.order_name, ''),
         'drive', 'drive', dl.id, null, null
    from public.deliveries dl join public.clients cl on cl.id = dl.client_id, unnest(cl.emails) ce
  union all
  select lower(x.lead_email), x.at, x.kind, x.direction, x.summary, x.actor, coalesce(x.source, 'touch'), x.ref, x.next_step, x.next_at
    from public.touches x;
revoke all on public.lead_timeline from anon;
grant select on public.lead_timeline to authenticated;

-- 3) deal_stages: one ladder; each stage says what must be TRUE to be in it (the exit criterion of the stage before).
--    probability + default_value_usd are DEFAULTS for the forecast: founders edit them (update public.deal_stages set …).
create table if not exists public.deal_stages (
  stage             text primary key,
  ord               int not null,
  is_open           boolean not null,
  entry_rule        text not null,
  probability       numeric not null check (probability between 0 and 1),
  default_value_usd numeric not null default 150,
  max_quiet_days    int
);
alter table public.deal_stages enable row level security;
revoke all on public.deal_stages from anon, authenticated;
drop policy if exists "founders read" on public.deal_stages;
drop policy if exists "founders edit" on public.deal_stages;
create policy "founders read" on public.deal_stages for select using (public.is_admin());
create policy "founders edit" on public.deal_stages for update using (public.is_admin()) with check (public.is_admin());
grant select, update (probability, default_value_usd, max_quiet_days) on public.deal_stages to authenticated;
insert into public.deal_stages (stage, ord, is_open, entry_rule, probability, default_value_usd, max_quiet_days) values
  ('replied',   1, true,  'They replied to us (a real reply, not an auto-reply).',                                   0.05, 150, 2),
  ('engaged',   2, true,  'A buying step happened: a sample said yes or delivered, a call booked, or a hot reply.',  0.15, 150, 3),
  ('proposal',  3, true,  'A price, pack link, plans page or scope was sent in writing.',                             0.25, 150, 7),
  ('committed', 4, true,  'They said yes or asked for the link. Leaves only by a payment.',                          0.60, 150, 3),
  ('won',       5, false, 'A payment exists (Stripe), or the Samples status is WON.',                               1.00, 150, null),
  ('parked',    6, false, 'Follow-up cadence finished with no answer. Re-engage later.',                             0.02, 150, null),
  ('lost',      7, false, 'Hard pass, no budget, or stopped, and no payment.',                                       0.00, 150, null)
on conflict (stage) do nothing;

-- 4) lead_stage: each lead's stage COMPUTED FROM EVIDENCE, with the evidence and the days in stage.
--    Order matters: the first true line wins (won > lost > parked > committed > proposal > engaged > replied).
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
       (ds.is_open and ds.max_quiet_days is not null and s.stage_since < now() - make_interval(days => ds.max_quiet_days)) as overdue
from s join public.deal_stages ds on ds.stage = s.stage;
revoke all on public.lead_stage from anon;
grant select on public.lead_stage to authenticated;

-- 5) pipeline_forecast: leads per stage, weighted by probability and deal value (open stages are the forecast).
create or replace view public.pipeline_forecast with (security_invoker = on) as
select ds.stage, ds.ord, ds.is_open, ds.probability, count(ls.email) as leads,
       count(ls.email) filter (where ls.overdue) as overdue,
       coalesce(sum(ls.deal_value_usd), 0) as value_usd,
       round(coalesce(sum(ls.deal_value_usd * ds.probability), 0)) as weighted_usd
from public.deal_stages ds left join public.lead_stage ls on ls.stage = ds.stage
group by ds.stage, ds.ord, ds.is_open, ds.probability
order by ds.ord;
revoke all on public.pipeline_forecast from anon;
grant select on public.pipeline_forecast to authenticated;
