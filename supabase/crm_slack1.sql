-- crm_slack1.sql (11-21, SIMAS: "we need to implement slack into the crm"). Needs crm_notify1.sql.
-- Additive only: slack_messages (a mirror of #claude-sync and #red-alert, filled every 2 minutes by the Edge Function
-- slack-sync via pg_cron, and right away by slack-post), an event trigger, realtime.
-- An event (kind 'slack') is raised for a message that @-mentions Simas or Benas, carries 🔴 / :red_circle:, or sits in
-- #red-alert. Founders read; only the service role writes.
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_slack1.sql

create table if not exists public.slack_messages (
  ts           text not null,
  channel_id   text not null,
  channel_name text,
  user_name    text,
  text         text,
  at           timestamptz,
  thread_ts    text,
  permalink    text,
  mentions     text[] not null default '{}',
  primary key (channel_id, ts)
);
create index if not exists slack_messages_at on public.slack_messages (at desc);
alter table public.slack_messages enable row level security;
revoke all on public.slack_messages from anon, authenticated;
drop policy if exists "founders read" on public.slack_messages;
create policy "founders read" on public.slack_messages for select using (public.is_admin());
grant select on public.slack_messages to authenticated;

create or replace function public.crm_ev_slack(r public.slack_messages, p_source text default 'slack') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare red boolean := coalesce(r.text, '') ~ '(🔴|:red_circle:)' or r.channel_name = 'red-alert';
        who text[] := array(select m from unnest(r.mentions) m where m in ('Simas', 'Benas'));
        lead text := lower(substring(coalesce(r.text, '') from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
begin
  if not red and cardinality(who) = 0 then return; end if;
  if lead ~ 'beju' or lead in ('juceviciussimas@gmail.com', 'benascool1@gmail.com') then   -- our own inboxes are not leads
    lead := null;
  end if;
  perform public.crm_event_add('slack', case when red then 'alert' else 'info' end,
    case when cardinality(who) > 0 then '@' || array_to_string(who, ' @') || ' in #' else '#' end || coalesce(r.channel_name, r.channel_id)
      || ' · ' || coalesce(r.user_name, 'someone'),
    left(r.text, 600), lead, r.permalink, p_source, 'slack:' || r.channel_id || ':' || r.ts, r.user_name, r.at);
end $$;
create or replace function public.crm_tg_slack() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.crm_ev_slack(new); return null; end $$;
drop trigger if exists crm_event on public.slack_messages;
create trigger crm_event after insert on public.slack_messages for each row execute function public.crm_tg_slack();
revoke all on function public.crm_ev_slack(public.slack_messages, text) from public, anon, authenticated;
revoke all on function public.crm_tg_slack() from public, anon, authenticated;

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'slack_messages') then
    alter publication supabase_realtime add table public.slack_messages;
  end if;
end $$;

-- The 2-minute schedule is created separately (it copies the x-cron-secret header from the ops-sync job server-side, so
-- the secret never sits in this public file):
--   select cron.schedule('slack-sync', '*/2 * * * *',
--     replace(replace((select command from cron.job where jobname = 'ops-sync'), '/functions/v1/ops-sync', '/functions/v1/slack-sync'),
--             'timeout_milliseconds := 120000', 'timeout_milliseconds := 60000'));
