-- crm_contacts1.sql (Benas's side, 11-21): ONE contacts list (BENAS approved the build 11-21).
-- One row per PERSON: a paying client is one row with all its addresses (clients.emails); everyone else is one row per
-- address. Built live from what we already store (pipeline, interested_leads, threads, reply_queue, clients, payments,
-- lead_stage, lead_next_step, orders, tasks, desk holds), so it can never drift. Only the facts nobody else stores live in
-- `contact_info` (phone, role, tags, notes, and name/company overrides), keyed by contact_id, written by founders (CRM).
-- ADDITIVE ONLY. Rollback: drop view public.contacts; drop table public.contact_info;

create table if not exists public.contact_info (
  contact_id  text primary key check (contact_id ~ '^client:[0-9a-f-]{36}$' or (contact_id = lower(contact_id) and contact_id ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$')),
                                               -- the contacts view's contact_id: 'client:<uuid>' for a client (stable when addresses
                                               -- change), else the lower-case address
  name        text check (name is null or char_length(name) <= 120),
  company     text check (company is null or char_length(company) <= 160),
  role        text check (role is null or char_length(role) <= 120),
  phone       text check (phone is null or char_length(phone) <= 40),
  linkedin    text check (linkedin is null or char_length(linkedin) <= 300),
  tags        text[] not null default '{}',
  notes       text check (notes is null or char_length(notes) <= 4000),
  updated_by  text,
  updated_at  timestamptz not null default now()
);
alter table public.contact_info enable row level security;
drop policy if exists "founders all" on public.contact_info;
create policy "founders all" on public.contact_info for all using (public.is_admin()) with check (public.is_admin());
revoke all on public.contact_info from anon, authenticated;
grant select, insert, update on public.contact_info to authenticated;

create or replace view public.contacts with (security_invoker = on) as
with cl as (                                   -- every client address -> its client
  select lower(x) e, c.id client_id from public.clients c, unnest(c.emails) x
), addr as (                                   -- every address we know, with the person it belongs to
  select e, coalesce((select 'client:' || cl.client_id from cl where cl.e = a.e limit 1), e) pkey
  from (select lower(email) e from public.pipeline where email is not null
        union select lower(email) from public.interested_leads where email is not null
        union select lower(lead_email) from public.threads where lead_email is not null
        union select lower(lead_email) from public.reply_queue where lead_email is not null
        union select e from cl) a
), people as (
  select pkey, array_agg(e order by e) emails from addr group by pkey
  union all                                    -- a client with no address on file still counts (e.g. paid by someone else)
  select 'client:' || c.id, '{}'::text[] from public.clients c where coalesce(array_length(c.emails, 1), 0) = 0
),
-- every per-person number is aggregated on its own first, so joining several sources never multiplies a count or a sum
th as (select a.pkey, min(t.at) first_at, max(t.at) last_at, max(t.at) filter (where t.direction = 'in') last_in_at, count(*) msgs,
              (array_agg(t.inbox order by t.at desc))[1] last_inbox
       from public.threads t join addr a on a.e = lower(t.lead_email) group by a.pkey),
pi as (select a.pkey, max(p.name) name, max(p.show) show, max(p.owner) owner, max(p.inbox) inbox, max(p.campaign) campaign, max(p.source) source
       from public.pipeline p join addr a on a.e = lower(p.email) group by a.pkey),
il as (select a.pkey, max(i.first_name) first_name, max(i.company) company, max(i.inbox) inbox, max(i.campaign) campaign
       from public.interested_leads i join addr a on a.e = lower(i.email) group by a.pkey),
st as (select a.pkey, (array_agg(s.stage order by s.ord desc nulls last))[1] stage, (array_agg(s.owner order by s.ord desc nulls last))[1] owner,
              max(s.name) name
       from public.lead_stage s join addr a on a.e = lower(s.email) group by a.pkey),
nx as (select a.pkey, (array_agg(n.next_step order by n.next_at nulls last))[1] next_step, min(n.next_at) next_at
       from public.lead_next_step n join addr a on a.e = lower(n.email) group by a.pkey),
pay as (   -- a payment belongs to its client, or (no client link) to the person whose address paid; never counted twice
       select pp.pkey, sum(p.amount) filter (where not p.refunded) usd, max(p.paid_at) last_paid_at
       from people pp join public.payments p
         on pp.pkey = 'client:' || p.client_id or (p.client_id is null and lower(p.email) = any(pp.emails))
       group by pp.pkey)
select pp.pkey contact_id,
       coalesce(c.emails[1], pp.emails[1]) primary_email,
       pp.emails,
       coalesce(ci.name, c.name, pi.name, st.name, il.first_name) name,
       coalesce(ci.company, c.show, pi.show, il.company) company,
       ci.role, ci.phone, ci.linkedin, coalesce(ci.tags, '{}') tags, ci.notes,
       nullif(case when split_part(coalesce(c.emails[1], pp.emails[1]), '@', 2)
                    ~ '^(gmail|googlemail|hotmail|outlook|yahoo|icloud|me|aol|live|msn|proton|protonmail)\.' then ''
                   else split_part(coalesce(c.emails[1], pp.emails[1]), '@', 2) end, '') company_domain,
       c.id client_id, coalesce(pay.usd, 0) > 0 is_client, coalesce(pay.usd, 0) lifetime_usd, pay.last_paid_at,
       st.stage, coalesce(st.owner, pi.owner) owner, nx.next_step, nx.next_at,
       coalesce(pi.inbox, il.inbox, th.last_inbox) inbox, coalesce(pi.campaign, il.campaign) campaign,
       th.first_at first_contact_at, th.last_at last_contact_at, th.last_in_at last_reply_at, coalesce(th.msgs, 0)::int messages,
       (select count(*) from public.orders o where o.client_id = c.id and o.status = 'open')::int open_orders,
       (select count(*) from public.tasks t where lower(t.lead_email) = any(pp.emails) and t.status in ('todo', 'doing'))::int open_tasks,
       (select count(*) from public.promises pr where lower(pr.lead_email) = any(pp.emails) and pr.status = 'open')::int open_promises,
       exists (select 1 from public.desk_items h where h.kind = 'hold' and h.status = 'open' and h.emails && pp.emails) on_hold,
       c.website, c.instagram, c.youtube, c.niche, coalesce(c.source, pi.source) source
from people pp
left join public.clients c on pp.pkey = 'client:' || c.id
left join public.contact_info ci on ci.contact_id = pp.pkey
left join th on th.pkey = pp.pkey
left join pi on pi.pkey = pp.pkey
left join il on il.pkey = pp.pkey
left join st on st.pkey = pp.pkey
left join nx on nx.pkey = pp.pkey
left join pay on pay.pkey = pp.pkey;
revoke all on public.contacts from anon, authenticated;
grant select on public.contacts to authenticated;   -- security_invoker: founders only, through the base tables' RLS
