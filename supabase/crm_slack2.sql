-- crm_slack2.sql (11-21, main-session review: the bell flooded with "#claude-sync · Benas's Claude" in red, no content).
-- A Slack message raises a CRM event ONLY when:
--   (a) it is in #red-alert                                  -> severity 'alert'
--   (b) its text has 🔴 or :red_circle:                       -> severity 'alert'
--   (c) it @-mentions a founder's Slack user id (<@U…>; stored in slack_messages.mentions as 'Simas' / 'Benas'),
--       and it is NOT an agent post ("[Simas's Claude] …", "[Benas's Claude] …": those count only through a or b) -> 'info'
-- Title = the message's own gist (prefix and Slack markup stripped, ~80 characters, cut at a word); the body starts with
-- "#channel · author". Existing slack events that miss the rule are removed, the rest re-titled (derived rows only).
-- Rollback: Beju Dashboard/scripts/data/work/crm_backend_1121/rollback_slack2.sql

create or replace function public.crm_slack_rule(r public.slack_messages) returns text
language sql immutable set search_path = public as $$
  select case
    when r.channel_id = 'C0CHQ5LV7L4' or r.channel_name = 'red-alert' then 'alert'
    when coalesce(r.text, '') ~ '(🔴|:red_circle:)' then 'alert'
    when coalesce(r.text, '') !~* '^\s*\[[^]]*claude[^]]*\]' and r.mentions && array['Simas', 'Benas'] then 'info'
  end
$$;

create or replace function public.crm_slack_gist(t text) returns text
language sql immutable set search_path = public as $$
  with a as (select regexp_replace(coalesce(t, ''), '^\s*\[[^]]{1,60}\]\s*', '') s),                     -- "[Benas's Claude] "
       b as (select regexp_replace(s, ':red_circle:', '🔴', 'g') s from a),
       c as (select regexp_replace(s, '<@[A-Z0-9]+(\|[^>]*)?>', '', 'g') s from b),                       -- raw <@U…>
       d as (select regexp_replace(s, '<(https?:[^|>]+)\|([^>]+)>', '\2', 'g') s from c),                 -- <url|label> -> label
       e as (select regexp_replace(s, '\s*\(https?://[^)[:space:]]+\)', '', 'g') s from d),               -- "label (url)" -> label
       f as (select regexp_replace(s, '<(https?:[^>]+)>', '\1', 'g') s from e),
       g as (select regexp_replace(s, '(^|(?<=[^[:alnum:]]))[*_~`]+|[*_~`]+((?=[^[:alnum:]])|$)', '', 'g') s from f),  -- *bold* _italic_ ~strike~ `code`
       h as (select btrim(regexp_replace(s, '\s+', ' ', 'g')) s from g)
  select case when length(s) <= 80 then s
              else coalesce(nullif(regexp_replace(left(s, 81), '\s+\S*$', ''), ''), left(s, 80)) || '…' end
    from h
$$;

create or replace function public.crm_ev_slack(r public.slack_messages, p_source text default 'slack') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare sev text := public.crm_slack_rule(r);
        head text := '#' || coalesce(r.channel_name, r.channel_id) || ' · ' || coalesce(r.user_name, 'someone');
        lead text := lower(substring(coalesce(r.text, '') from '([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'));
begin
  if sev is null then return; end if;
  if lead ~ 'beju' or lead in ('juceviciussimas@gmail.com', 'benascool1@gmail.com') then lead := null; end if;   -- our own inboxes
  perform public.crm_event_add('slack', sev, coalesce(nullif(public.crm_slack_gist(r.text), ''), head),
    head || E'\n' || left(coalesce(r.text, ''), 600), lead, r.permalink, p_source, 'slack:' || r.channel_id || ':' || r.ts, r.user_name, r.at);
end $$;
revoke all on function public.crm_slack_rule(public.slack_messages) from public, anon, authenticated;
revoke all on function public.crm_slack_gist(text) from public, anon, authenticated;
revoke all on function public.crm_ev_slack(public.slack_messages, text) from public, anon, authenticated;

-- existing derived rows: drop the ones the rule no longer raises (their crm_event_state rows cascade), re-title the rest
delete from public.crm_events e
 where e.kind = 'slack'
   and not exists (select 1 from public.slack_messages m
                    where e.ref = 'slack:' || m.channel_id || ':' || m.ts and public.crm_slack_rule(m) is not null);
update public.crm_events e
   set title = coalesce(nullif(public.crm_slack_gist(m.text), ''), '#' || coalesce(m.channel_name, m.channel_id) || ' · ' || coalesce(m.user_name, 'someone')),
       body = '#' || coalesce(m.channel_name, m.channel_id) || ' · ' || coalesce(m.user_name, 'someone') || E'\n' || left(coalesce(m.text, ''), 600),
       severity = public.crm_slack_rule(m)
  from public.slack_messages m
 where e.kind = 'slack' and e.ref = 'slack:' || m.channel_id || ':' || m.ts;
