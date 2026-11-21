-- Revenue per cold-email campaign (SIMAS 11-21: "in the email test tab ... how much has the campaigns generated revenue each").
-- Additive only. Same protection as the other founder tables: row-level security with is_admin(), no anon access.
-- Rollback: Beju Dashboard/scripts/data/work/crm_data_1121/crm_revenue1_rollback.sql

-- 1) lead_campaigns: which Instantly campaign each payer / lead was contacted from. Written ONLY by the service role
--    (scripts/lead_campaigns_sync.py, Dashboard repo, hourly from crm_panels_sync.py); founders read it.
--    A lead can sit in several campaigns: campaign_id = the one that emailed them first (earliest added among the contacted
--    records); the others are in also_in, a same-minute tie is written in note.
--    source: 'instantly' (found by email in Instantly) | 'interested_leads' (not in Instantly any more; campaign from
--    interested_leads) | 'not_found' (campaign_id null: website, referral, Instagram, other).
create table if not exists public.lead_campaigns (
  email            text primary key check (email = lower(email)),
  campaign_id      text,
  campaign_name    text,
  source           text not null,
  synced_at        timestamptz not null default now(),
  added_at         timestamptz,          -- when the lead was added to that campaign (Instantly timestamp_created)
  last_contact_at  timestamptz,          -- Instantly timestamp_last_contact in that campaign
  also_in          text[] not null default '{}',
  note             text,
  client_id        uuid                  -- the client this lead became, when it paid from ANOTHER address (pipeline 'paid' time =
                                         -- a payment of that client; lead_campaigns_sync.client_links). Devin: lead devin@just-approach.com,
                                         -- paid from a gmail.
);
alter table public.lead_campaigns add column if not exists client_id uuid;
create index if not exists lead_campaigns_campaign on public.lead_campaigns (campaign_id);
alter table public.lead_campaigns enable row level security;
drop policy if exists "founders read" on public.lead_campaigns;
create policy "founders read" on public.lead_campaigns for select using (public.is_admin());
revoke all on public.lead_campaigns from anon;
revoke insert, update, delete, truncate, references, trigger on public.lead_campaigns from authenticated;
grant select on public.lead_campaigns to authenticated;

-- 2) campaign_revenue: non-refunded payments per campaign. A payment is tied to a campaign through every email of its payer:
--    the payment's own email, all emails of its client (clients.emails) and the lead emails linked to that client
--    (lead_campaigns.client_id). Several matches = the campaign that emailed that person first. Payments with no match = one
--    row, campaign_id 'unattributed' (website, referral, other).
--    payers = distinct people (client id, else payer email). security_invoker: the reader's own RLS applies (founders only).
create or replace view public.campaign_revenue with (security_invoker = on) as
with pay as (
  select p.id, p.amount, p.paid_at, coalesce(p.client_id::text, lower(p.email)) as person
  from public.payments p
  where not coalesce(p.refunded, false)
),
pay_emails as (
  select p.id, lower(p.email) as email from public.payments p where p.email is not null and p.email <> ''
  union
  select p.id, lower(e) from public.payments p join public.clients c on c.id = p.client_id cross join lateral unnest(c.emails) e
  union
  select p.id, lc.email from public.payments p join public.lead_campaigns lc on lc.client_id = p.client_id
),
attr as (
  select distinct on (pe.id) pe.id, lc.campaign_id, lc.campaign_name
  from pay_emails pe
  join public.lead_campaigns lc on lc.email = pe.email and lc.campaign_id is not null
  order by pe.id, lc.added_at nulls last, lc.campaign_id
)
select coalesce(a.campaign_id, 'unattributed')                              as campaign_id,
       coalesce(max(a.campaign_name), 'Unattributed (website, referral, other)') as campaign_name,
       round(sum(pay.amount), 2)                                             as revenue_usd,
       count(distinct pay.person)                                            as payers,
       count(*)                                                              as payments,
       min(pay.paid_at)                                                      as first_paid_at,
       max(pay.paid_at)                                                      as last_paid_at
from pay
left join attr a on a.id = pay.id
group by coalesce(a.campaign_id, 'unattributed');
revoke all on public.campaign_revenue from anon, authenticated;
grant select on public.campaign_revenue to authenticated;

-- Check after applying: as a founder, select * from campaign_revenue order by revenue_usd desc works and
-- sum(revenue_usd) = (select sum(amount) from payments where not coalesce(refunded,false)); a client login gets 0 rows.
