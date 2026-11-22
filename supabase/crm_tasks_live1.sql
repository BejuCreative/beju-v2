-- crm_tasks_live1.sql (Benas's Claude, 2026-11-22)
-- BENAS 11-22 14:3x: "where is the work on the CRM? ... the to-do list task not being changed". The tasks list only moved when
-- someone edited it by hand. This makes it move by itself:
--   (1) every REAL reply waiting on us becomes a task for the inbox owner's side (source 'reply'), with the same filters as the
--       "Replies waiting" list in crm/crm.js (not answered, not dismissed, not a hard pass, not an auto-reply, lead not lost or
--       snoozed); the task closes itself when we answer (done) or the reply stops waiting for another reason (dropped);
--   (2) a lost reason in lead_flags closes that lead's AUTOMATIC tasks (sources 'reply' and 'claude'); founder / board tasks stay;
--   (3) runs every 5 minutes (pg_cron 'reply-tasks') and writes sync_status 'reply_tasks'.
-- Regexes are crm.js HARD_PASS / AUTO_TX / AUTO_MORE / YES_TX / HUMAN_TX / ownWords / ownerOfInbox ported to Postgres ARE
-- (\b -> \y). Keep both copies in step.

-- tasks.source gains 'reply' (same list as crm_tasks1.sql + 'reply')
alter table public.tasks drop constraint if exists tasks_source_check;
alter table public.tasks add constraint tasks_source_check
  check (source in ('manual', 'board', 'founder_tasks', 'call', 'deferred', 'claude', 'reply'));

create or replace function public.inbox_owner(ib text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case when coalesce(ib, '') ~* '^(simas|simon|team|editor|studio)@' then 'Simas'
              when coalesce(ib, '') ~* '^(ben|benas|hello|official|info)@' then 'Benas'
              else 'Both' end
$$;

-- the lead's own words, not the quoted thread (crm.js ownWords)
create or replace function public.reply_own_words(t text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select (regexp_split_to_array(coalesce(t, ''), '\yFrom: |\yOn .{5,120}?wrote:|-----Original Message-----|\ySent from my\y'))[1]
$$;

-- true when a waiting reply is not real work: a hard pass or an auto-reply (crm.js HARD_PASS || autoText)
create or replace function public.reply_is_noise(t text) returns boolean
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  w text := public.reply_own_words(t);
  hard_pass constant text := '\y(?:going to|gonna|will|''ll|have to|must|i|we)\s+pass\y(?!\s+(?:this|it|that|them|your|you|the|along|on to|on your|on the))|\ypass(?:ing)? on (?:this|it|that|the offer|your offer)\y|\yno,?\s+thanks?\y|\yno thank you\y|\ynot interested\y|\ynot for (?:us|me)\y|\yplease (?:don''?t|do not) (?:follow up|contact|email|reach out|send)|^\W*(?:stop|unsubscribe|remove me)\y';
  auto_tx constant text := 'out of (the )?office|\yOOO\y|on (vacation|holiday|leave|maternity)|auto(matic)?[- ]?reply|thank(s| you)( so much| very much)? for (your (email|message|e-mail|inquiry|enquiry|note)|reaching|getting|emailing|contacting)|your (message|email) has been (received|forwarded)|you will receive a (response|reply)|vielen dank f|(reply|respond|get back)[^.]{0,40}(upon|on|after) my return|away at a conference|reply above this line|your request (\(#?\d+\) )?has been received|we strive to respond within|limited access to (my )?e-?mails?|for (the )?fastest (assistance|response)|we (aim to )?(respond|reply) to (all )?e-?mails? within|in the meantime, here are|view (this email )?in (your )?browser|unsubscribe';
  auto_more constant text := '\y(we(''ve)?|i(''ve)?|team has) received your (message|e-?mail|inquiry|enquiry|note)\y|\y(has|have) landed (safe|safely)\y|\ymy working hours\y|\yonly check (this|my) (e-?mail|inbox)\y|\ythanks? (so much )?for writing in\y|\yyour (request|ticket)\y[^.]{0,30}\yhas been received\y';
  yes_tx constant text := '\y(yes|yeah|sure|interested|go ahead|send it|please do|sounds good|let''?s do|i''?d (like|love|be happy)|take you up on)\y';
  human_tx constant text := 'sorry for the (late|delayed|slow) (reply|response)|\yi was (out|away|travell?ing)\y|\y(adding|looping in|cc''?ing|copying in)\y|\yi''?ve (now )?(reviewed|watched|looked)|\y(aren''?t|are not|am not|i''?m not|not) (currently )?(looking for|interested)|\yno,? thank(s| you)\y|\y(just|i''?ve|we''?ve|i|we) (just )?paid\y|looking forward to working (together|with)';
begin
  if w ~* hard_pass then return true; end if;
  if w ~* '\yautomated (e-?mail |email )?(response|reply|message)\y' then return true; end if;
  return (w ~* auto_tx or w ~* auto_more) and not (w ~* yes_tx) and not (w ~* human_tx);
end $$;

-- the replies that are real work right now (same rules as crm.js d.replyWait); one row per lead (reply_queue keeps the latest)
create or replace function public.reply_wait()
returns table (lead_email text, inbox text, received_at timestamptz, snippet text, name text, owner text, ref text)
language sql stable security definer set search_path = public, pg_temp as $$
  select lower(r.lead_email), r.inbox, r.received_at, r.snippet, p.name, p.owner,
         'reply:' || lower(r.lead_email) || ':' || to_char(r.received_at at time zone 'UTC', 'YYYYMMDDHH24MISS')
    from public.reply_queue r
    left join public.pipeline p on p.email = r.lead_email
    left join public.lead_flags f on f.email = lower(r.lead_email)
   where r.kind = 'REAL' and not r.answered and not r.blocklisted and r.received_at is not null
     and not exists (select 1 from public.reply_dismissals d where lower(d.lead_email) = lower(r.lead_email)
                      and d.received_at >= r.received_at - interval '1 minute')
     and not exists (select 1 from public.threads h where lower(h.lead_email) = lower(r.lead_email)
                      and h.direction = 'out' and h.at > r.received_at)
     and (f.email is null or (f.lost_reason is null and (f.snoozed_until is null or f.snoozed_until <= now())))
     and not public.reply_is_noise(r.snippet)
$$;
revoke execute on function public.reply_wait() from public, anon, authenticated;

create or replace function public.reply_tasks_sync() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; c int := 0; l int := 0;
begin
  insert into public.tasks (title, detail, owner, status, due_at, lead_email, source, source_ref, created_by)
  select format('Reply to %s', coalesce(nullif(w.name, ''), w.lead_email)),
         left(trim(public.reply_own_words(w.snippet)), 300),
         case when w.owner in ('Simas', 'Benas') then w.owner else public.inbox_owner(w.inbox) end,
         'todo', w.received_at, w.lead_email, 'reply', w.ref, 'reply-tasks'
    from public.reply_wait() w
  on conflict (source, source_ref) do nothing;
  get diagnostics n = row_count;

  -- a reply task closes itself once its reply stops waiting: we answered (done) or it was dismissed / blocklisted /
  -- turned out to be noise / the lead went lost or snoozed / a newer reply replaced it (dropped; the newer one gets its own task)
  update public.tasks t
     set status = case when exists (select 1 from public.reply_queue r where lower(r.lead_email) = t.lead_email
                                     and r.received_at = t.due_at and r.answered)
                         or exists (select 1 from public.threads h where lower(h.lead_email) = t.lead_email
                                     and h.direction = 'out' and h.at > t.due_at)
                       then 'done' else 'dropped' end,
         done_at = now(), updated_at = now()
   where t.source = 'reply' and t.status in ('todo', 'doing')
     and not exists (select 1 from public.reply_wait() w where w.ref = t.source_ref);
  get diagnostics c = row_count;

  -- a lost reason closes the lead's automatic tasks (reply + no-reply follow-up reminders); founder and board tasks stay
  update public.tasks t set status = 'dropped', done_at = now(), updated_at = now()
   where t.source in ('reply', 'claude') and t.status in ('todo', 'doing') and t.lead_email is not null
     and exists (select 1 from public.lead_flags f where f.email = lower(t.lead_email) and f.lost_reason is not null);
  get diagnostics l = row_count;

  insert into public.sync_status (name, ran_at, ok, detail)
  values ('reply_tasks', now(), true, format('%s new, %s closed, %s closed (lost lead)', n, c, l))
  on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  return n;
end $$;
revoke execute on function public.reply_tasks_sync() from public, anon, authenticated;

select cron.unschedule('reply-tasks') where exists (select 1 from cron.job where jobname = 'reply-tasks');
select cron.schedule('reply-tasks', '*/5 * * * *', $$select public.reply_tasks_sync()$$);

-- crm-api gains a read action `todo` (the unified open list, public.task_queue). Key rights stay a hand step for the key owner
-- (same as crm_orders2.sql): to let every key that reads `tasks` also read `todo`, run once after the function deploy:
--   update public.api_keys set actions = array(select distinct unnest(actions || array['todo'])) where 'tasks' = any(actions);
