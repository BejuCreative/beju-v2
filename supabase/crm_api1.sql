-- crm-api v1 (11-21, Simas: "do what u can"): per-caller keys + a call log for the crm-api Edge Function.
-- Additive: two new tables, nothing existing is changed.
-- api_keys holds only a SHA-256 hash of each key (the key itself is never stored) and the actions that key may run.
-- Switch a key off: update public.api_keys set revoked_at = now() where name = '<name>';

create table if not exists public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,          -- the caller, also the actor tag on every write (e.g. benas-claude)
  key_hash     text not null unique,          -- sha256 hex of the key
  actions      text[] not null,               -- what this key may run
  created_at   timestamptz not null default now(),
  created_by   text,
  revoked_at   timestamptz,
  last_used_at timestamptz
);
alter table public.api_keys enable row level security;
revoke all on public.api_keys from anon, authenticated;   -- service role only (the Edge Function); no policies on purpose

create table if not exists public.api_log (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  key_name  text,
  action    text,
  args      jsonb,
  ok        boolean,
  status    int,
  error     text
);
create index if not exists api_log_at on public.api_log (at desc);
alter table public.api_log enable row level security;
revoke all on public.api_log from anon, authenticated;
drop policy if exists "founders read" on public.api_log;
create policy "founders read" on public.api_log for select using (public.is_admin());
grant select on public.api_log to authenticated;            -- founders can read who did what; nobody but the function writes
