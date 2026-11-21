-- crm_webhook1.sql (Benas's side, 11-21): instant updates from Instantly.
-- Every webhook call lands here once (unique source + event_key), so a retried or duplicated delivery is ignored.
-- The instantly-webhook function then refreshes that lead's reply_queue row + threads exactly like ops-sync does,
-- which fires the existing crm_event trigger (bell + Slack) within seconds. ops-sync keeps running every 10 min as
-- the safety net and writes the same rows (same keys), so nothing is double-counted. Additive only: no existing
-- table, function or trigger is changed. Rollback: drop table public.webhook_inbox;
create table if not exists public.webhook_inbox (
  id bigserial primary key,
  source text not null,                       -- 'instantly'
  event_key text not null,                    -- the provider's event/email id, else a hash of the payload
  event_type text,                            -- reply_received, lead_interested, email_bounced, ...
  lead_email text,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  result text,                                -- what the function did, or why it skipped
  error text,
  unique (source, event_key)
);
create index if not exists webhook_inbox_recent on public.webhook_inbox (received_at desc);

alter table public.webhook_inbox enable row level security;
drop policy if exists "founders read" on public.webhook_inbox;
create policy "founders read" on public.webhook_inbox for select using (public.is_admin());
revoke all on public.webhook_inbox from anon, authenticated;
grant select on public.webhook_inbox to authenticated;      -- reads only, and RLS limits them to founders
-- writes: the function only, with the service role (bypasses RLS); no client or agent key can write here.
