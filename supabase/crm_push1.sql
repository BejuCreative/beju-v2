-- crm_push1.sql (Benas's Claude, 2026-11-25): iPhone notifications for the founder CRM (Web Push).
-- WHY: BENAS 11-25 "iPhone notifications": a founder with the CRM on the home screen gets a lock-screen alert for
--   money (a new payment), reply (a new reply waiting), sample_yes (a lead said yes to the free Short) and
--   client_changes (a client asked for changes). iOS allows Web Push only for a home-screen web app (16.4+), and the
--   permission must come from a tap in the CRM page (Notifications, in the account sheet).
-- DESIGN (simplest reliable): a DB trigger on each source table writes ONE row into push_outbox. A trigger can never
--   block or fail the original write (every trigger body is wrapped in `exception when others`). pg_cron calls the edge
--   function push-send every minute (x-cron-secret, like draft-sender); it claims the outbox rows, sends Web Push to every
--   enabled device and disables devices that answer 404/410. Latency: up to about a minute.
-- ADDITIVE ONLY. Nothing here changes an existing table, view or policy.
-- APPLY ORDER: 1) this file, 2) set the 3 secrets + deploy push-send (--no-verify-jwt), 3) run the cron block at the
--   bottom with the real CRON_SECRET (never commit it).
-- Rollback: see the bottom of the file.
begin;

-- ---------------------------------------------------------------- devices
create table if not exists public.push_subs (
  id             bigint generated always as identity primary key,
  user_id        uuid not null default auth.uid() references public.profiles(id) on delete cascade,   -- the founder (profiles.id = auth.uid())
  founder        text,                                  -- 'Simas' / 'Benas' (profiles.name at save time; for the logs only)
  endpoint       text not null unique,                  -- the browser push service URL: one row per device
  p256dh         text not null,
  auth           text not null,
  user_agent     text check (user_agent is null or char_length(user_agent) <= 300),
  events         text[] not null default array['money', 'reply', 'sample_yes', 'client_changes']
                 check (events <@ array['money', 'reply', 'sample_yes', 'client_changes']),
  created_at     timestamptz not null default now(),
  last_ok_at     timestamptz,                           -- last push the push service accepted
  failed_count   int not null default 0,                -- consecutive failures (reset on success)
  disabled_at    timestamptz                            -- set by push-send on 404/410 (gone) or after 10 failures; null = live
);
create index if not exists push_subs_live_idx on public.push_subs (user_id) where disabled_at is null;

alter table public.push_subs enable row level security;
-- a logged-in founder (is_admin(): profile flag + 2-step login) sees and changes only their OWN devices; the service role bypasses RLS
drop policy if exists "own devices read" on public.push_subs;
create policy "own devices read" on public.push_subs for select using (public.is_admin() and user_id = auth.uid());
drop policy if exists "own devices insert" on public.push_subs;
create policy "own devices insert" on public.push_subs for insert with check (public.is_admin() and user_id = auth.uid());
drop policy if exists "own devices update" on public.push_subs;
create policy "own devices update" on public.push_subs for update using (public.is_admin() and user_id = auth.uid()) with check (public.is_admin() and user_id = auth.uid());
drop policy if exists "own devices delete" on public.push_subs;
create policy "own devices delete" on public.push_subs for delete using (public.is_admin() and user_id = auth.uid());
revoke all on public.push_subs from anon, authenticated;
grant select, delete on public.push_subs to authenticated;
grant insert (endpoint, p256dh, auth, user_agent, events) on public.push_subs to authenticated;   -- user_id comes from the default (auth.uid())
grant update (events, user_agent) on public.push_subs to authenticated;                           -- the toggles; keys, owner and health columns are never client-writable

-- The page saves a device through this function: the same phone can be signed in as the other founder later, and a plain
-- upsert would then hit the other founder's row (RLS). Here the row moves to whoever is signed in (a real founder only).
create or replace function public.push_sub_save(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null, p_events text[] default null)
returns public.push_subs
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.push_subs; nm text;
begin
  if not public.is_admin() then raise exception 'founders only' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'bad subscription'; end if;
  select name into nm from public.profiles where id = auth.uid();
  insert into public.push_subs as s (user_id, founder, endpoint, p256dh, auth, user_agent, events)
  values (auth.uid(), nm, p_endpoint, p_p256dh, p_auth, left(p_ua, 300), coalesce(p_events, array['money', 'reply', 'sample_yes', 'client_changes']))
  on conflict (endpoint) do update set user_id = auth.uid(), founder = nm, p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, events = coalesce(p_events, s.events), disabled_at = null, failed_count = 0
  returning * into r;
  return r;
end $$;
revoke all on function public.push_sub_save(text, text, text, text, text[]) from public, anon;
grant execute on function public.push_sub_save(text, text, text, text, text[]) to authenticated;

-- ---------------------------------------------------------------- queue
create table if not exists public.push_outbox (
  id          bigint generated always as identity primary key,
  event       text not null check (event in ('money', 'reply', 'sample_yes', 'client_changes')),
  ref         text not null,                      -- what happened, for de-duplication (e.g. 'task:123'); one notification per (event, ref)
  title       text not null check (char_length(title) <= 120),
  body        text not null default '' check (char_length(body) <= 200),
  url         text not null default './',         -- where a tap goes, relative to /crm/ (e.g. '?p=todos')
  tag         text not null,                      -- the phone replaces a notification with the same tag instead of stacking it
  status      text not null default 'new' check (status in ('new', 'sending', 'sent', 'skipped', 'failed')),
  attempts    int not null default 0,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  sent_at     timestamptz,
  detail      text,
  unique (event, ref)
);
create index if not exists push_outbox_new_idx on public.push_outbox (id) where status in ('new', 'sending');
alter table public.push_outbox enable row level security;   -- no policy: only the service role (push-send) and the triggers below touch it
revoke all on public.push_outbox from anon, authenticated;

-- push-send claims a batch atomically (a second run can't take the same rows); a claim stuck for 5 minutes is retried, max 3 attempts
create or replace function public.push_outbox_claim(n int default 50)
returns setof public.push_outbox
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.push_outbox where created_at < now() - interval '14 days' and status in ('sent', 'skipped', 'failed');
  update public.push_outbox set status = 'failed', detail = 'gave up after 3 attempts' where status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts >= 3;
  return query
    update public.push_outbox o set status = 'sending', claimed_at = now(), attempts = o.attempts + 1
     where o.id in (select q.id from public.push_outbox q
                     where (q.status = 'new' or (q.status = 'sending' and q.claimed_at < now() - interval '5 minutes' and q.attempts < 3))
                       and q.created_at > now() - interval '6 hours'      -- a stale alert is noise, not news
                     order by q.id limit greatest(1, least(n, 200)) for update skip locked)
    returning o.*;
end $$;
revoke all on function public.push_outbox_claim(int) from public, anon, authenticated;
grant execute on function public.push_outbox_claim(int) to service_role;

-- ---------------------------------------------------------------- triggers (one per event)
-- Lock-screen text only: a first name or an amount, never an email, a thread or a note. A failure inside a trigger is swallowed:
-- the original write (a Stripe payment, a reply task, a sheet sync, a board change) must never fail because of a notification.
create or replace function public.push_first(n text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select coalesce(nullif(split_part(btrim(coalesce(n, '')), ' ', 1), ''), 'a lead')
$$;

-- money: a new payment row (stripe-webhook writes public.payments). Only a fresh, non-refunded one: an import of old rows stays quiet.
create or replace function public.push_on_payment() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if coalesce(new.refunded, false) = false and coalesce(new.amount, 0) > 0 and coalesce(new.paid_at, now()) > now() - interval '1 day' then
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('money', 'pay:' || new.id, '💰 Payment in: $' || trim(trailing '.' from trim(trailing '0' from to_char(new.amount, 'FM999999990.00'))),
              'Tap to open the CRM', '?p=clients', 'money:' || new.id)
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_payment on public.payments;
create trigger push_payment after insert on public.payments for each row execute function public.push_on_payment();

-- reply: a new task with source 'reply' (public.reply_tasks_sync(), every 5 minutes, makes one per real reply waiting)
create or replace function public.push_on_reply_task() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare nm text;
begin
  begin
    if new.source = 'reply' and new.status = 'todo' and new.created_at > now() - interval '1 day' then
      select p.name into nm from public.pipeline p where lower(p.email) = lower(new.lead_email) limit 1;
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('reply', 'task:' || new.id, 'New reply waiting: ' || public.push_first(nm), 'Tap to open the to-do list', '?p=todos', 'reply:' || new.id)
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_reply_task on public.tasks;
create trigger push_reply_task after insert on public.tasks for each row execute function public.push_on_reply_task();

-- sample_yes: a pipeline row inserted as, or changed to, status 'YES' (a lead said yes to the free Short)
create or replace function public.push_on_sample_yes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status = 'YES' and (tg_op = 'INSERT' or old.status is distinct from 'YES') and coalesce(new.yes_at, now()) > now() - interval '2 days' then
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('sample_yes', 'yes:' || lower(new.email) || ':' || to_char(coalesce(new.yes_at, now()) at time zone 'UTC', 'YYYYMMDD'),
              'Sample yes: ' || public.push_first(new.name), 'Tap to open the samples board', '?p=samples', 'yes:' || lower(new.email))
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_sample_yes on public.pipeline;
create trigger push_sample_yes after insert or update of status on public.pipeline for each row execute function public.push_on_sample_yes();

-- client_changes: a client_items row that changes to status 'changes' (a client asked for changes on a delivered Short)
create or replace function public.push_on_client_changes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status = 'changes' and (tg_op = 'INSERT' or old.status is distinct from 'changes') then
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('client_changes', 'item:' || new.id || ':' || to_char(coalesce(new.status_at, now()) at time zone 'UTC', 'YYYYMMDDHH24MISS'),
              'Changes asked: ' || public.push_first(new.client_name), 'Tap to open the client board',
              case when new.client_id is not null then '?p=clients&c=' || new.client_id else '?p=clients' end,
              'changes:' || coalesce(new.client_id::text, new.id::text))
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_client_changes on public.client_items;
create trigger push_client_changes after insert or update of status on public.client_items for each row execute function public.push_on_client_changes();

commit;

-- ---------------------------------------------------------------- cron (run AFTER push-send is deployed and its 3 secrets are set)
-- Replace <CRON_SECRET> with the value the other cron jobs use (Supabase secret CRON_SECRET) when applying; never commit it.
-- select cron.unschedule('push-send') where exists (select 1 from cron.job where jobname = 'push-send');
-- select cron.schedule('push-send', '* * * * *', $$
--   select net.http_post(url := 'https://zfnpvcrnujxlycmqukqs.supabase.co/functions/v1/push-send',
--                        headers := '{"x-cron-secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
--                        body := '{}'::jsonb, timeout_milliseconds := 30000)
-- $$);

-- ---------------------------------------------------------------- rollback
-- select cron.unschedule('push-send');
-- drop trigger if exists push_payment on public.payments;            drop function if exists public.push_on_payment();
-- drop trigger if exists push_reply_task on public.tasks;            drop function if exists public.push_on_reply_task();
-- drop trigger if exists push_sample_yes on public.pipeline;         drop function if exists public.push_on_sample_yes();
-- drop trigger if exists push_client_changes on public.client_items; drop function if exists public.push_on_client_changes();
-- drop function if exists public.push_first(text); drop function if exists public.push_outbox_claim(int);
-- drop function if exists public.push_sub_save(text, text, text, text, text[]);
-- drop table if exists public.push_outbox; drop table if exists public.push_subs;
