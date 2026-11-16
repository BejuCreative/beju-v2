-- Retainers (Simas 11-17: "add another square that shows the clients that are recurring, only count them if they
-- bought a retainer"). One row per Stripe subscription (monthly plans), filled by scripts/crm_sync.py (service role).
-- Repeat pack buyers are NOT retainers.
create table if not exists public.retainers (
  id text primary key,                 -- Stripe subscription id
  email text,
  name text,
  amount numeric,                      -- per interval, in currency units
  currency text,
  interval text,                       -- month / year / week
  status text,                         -- active, past_due, canceled, ...
  started_at timestamptz,
  current_period_end timestamptz,      -- next bill
  cancel_at_period_end boolean default false,
  canceled_at timestamptz,
  paid_total numeric default 0,        -- all paid invoices of this subscription
  invoices_paid int default 0,
  updated_at timestamptz not null default now()
);
alter table public.retainers enable row level security;
drop policy if exists "founders read" on public.retainers;
create policy "founders read" on public.retainers for select using (public.is_admin());
