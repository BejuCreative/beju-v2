-- Founder tasks (Simas 11-16: "do next should be practical ... reply to Kiid Coffee is your task, so we don't have to
-- step a foot in there"). Only things a FOUNDER must do: calls, Stripe settings, a decision, a client only they can
-- talk to. The Claudes add rows (scripts/founder_tasks.py in the Dashboard repo); founders tick them done in the CRM.
create table if not exists public.founder_tasks (
  id bigserial primary key,
  title text not null,
  detail text,
  who text,                  -- 'Simas' | 'Benas' | null = either founder
  lead_email text,
  due_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists founder_tasks_open on public.founder_tasks (done_at, due_at);
alter table public.founder_tasks enable row level security;
drop policy if exists "founders read" on public.founder_tasks;
create policy "founders read" on public.founder_tasks for select using (public.is_admin());
drop policy if exists "founders tick" on public.founder_tasks;
create policy "founders tick" on public.founder_tasks for update using (public.is_admin()) with check (public.is_admin());
