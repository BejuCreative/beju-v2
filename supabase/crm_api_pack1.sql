-- crm_api_pack1.sql (Simas's Claude, 2026-11-22): crm-api pack 1 = read `unhandled`, read `health`, write `beat`.
-- Why: each side computed "which replies wait" in its own script and the counts disagreed (needs_attention vs reply_wait()),
-- and a dead watcher or a red sync was invisible to the other side. One SQL definition per question; crm-api is a thin wrapper.
--
-- Part A is additive (a new function, a new view, a new column + its values). Part B changes the reply rows of needs_attention.
-- Re-run safe. APPLIED to prod 2026-11-22 ~17:20 Vilnius (Part A + Part B, one transaction), after a rolled-back dry run showed
-- needs_attention keeps its 7 columns, types, grants and security_invoker, and every non-reply row is identical (EXCEPT ALL both
-- ways = 0). Only the reply rows changed: 3 -> 0 (1 hard pass + 2 auto-replies), = reply_wait().

-- ============================================================ Part A (additive)

-- A1. reply_wait() for readers. reply_wait() (crm_tasks_live1.sql) is SECURITY DEFINER and runs for postgres + service_role
-- only, so a security_invoker view that calls it fails for a founder logged in to the CRM. This wrapper gives its rows to a
-- founder (is_admin: admin + 2-step), to the service role (crm-api, crm.py) and to direct DB sessions (pg_cron, SQL editor).
-- Any other caller gets no rows (same as RLS on reply_queue). anon cannot run it.
create or replace function public.reply_wait_read()
returns table (lead_email text, inbox text, received_at timestamptz, snippet text, name text, owner text, ref text)
language sql stable security definer set search_path = public, pg_temp as $$
  select w.lead_email, w.inbox, w.received_at, w.snippet, w.name, w.owner, w.ref
    from public.reply_wait() w
   where public.is_admin()
      or coalesce(auth.role(), '') = 'service_role'
      or session_user <> 'authenticator'
$$;
revoke execute on function public.reply_wait_read() from public, anon;
grant execute on function public.reply_wait_read() to authenticated, service_role;

-- A2. unhandled: every real reply waiting on us (reply_wait()), who holds the thread, how long it waits, and the flags that
-- change who may answer. crm-api `unhandled` reads this; crm.py can read the same view.
--   side          the lead's owner in pipeline, else the inbox owner (Simas / Benas / Both)
--   said          the lead's own words (quoted thread cut off), max 300 chars
--   claimed_by    the actor holding an unexpired thread claim (thread_claims), claim_until = when it ends
--   on_hold       an open desk hold names this address (FOUNDER HOLD)
--   big_50k       what the DB knows of a 50k+ audience: the lead came in through a 50k+ campaign, or a tracked account of
--                 theirs has 50k+ followers. Audience size of other leads is not stored, so false does not prove small.
--   is_client     paid us before (payments, not refunded) or is on a clients row
create or replace view public.unhandled as
  select w.lead_email, w.name, w.inbox,
         coalesce(nullif(w.owner, ''), public.inbox_owner(w.inbox)) as side,
         w.received_at,
         floor(extract(epoch from now() - w.received_at) / 60)::int as waiting_min,
         left(trim(public.reply_own_words(w.snippet)), 300) as said,
         c.actor as claimed_by, c.expires_at as claim_until,
         exists (select 1 from public.desk_items h, unnest(h.emails) e
                  where h.kind = 'hold' and h.status = 'open' and lower(e) = w.lead_email) as on_hold,
         (exists (select 1 from public.interested_leads i where lower(i.email) = w.lead_email and i.campaign ~* '50k\+')
          or exists (select 1 from public.client_accounts a where lower(a.email) = w.lead_email and a.followers >= 50000)) as big_50k,
         (exists (select 1 from public.payments p where lower(p.email) = w.lead_email and not p.refunded)
          or exists (select 1 from public.clients k, unnest(k.emails) e where lower(e) = w.lead_email)) as is_client,
         (select count(*) from public.promises p where lower(p.lead_email) = w.lead_email and p.status = 'open')::int as open_promises,
         exists (select 1 from public.drafts_waiting d where lower(d.lead_email) = w.lead_email) as draft_waiting,
         (select max(t.at) from public.threads t where lower(t.lead_email) = w.lead_email and t.direction = 'out') as our_last_out,
         w.ref
    from public.reply_wait_read() w
    left join public.thread_claims c on c.lead_email = w.lead_email and c.expires_at > now();
alter view public.unhandled set (security_invoker = on);
revoke all on public.unhandled from anon, authenticated;
grant select on public.unhandled to authenticated;   -- founders read (RLS on every table below is is_admin()); no writes

-- A3. Freshness rule per sync_status row + heartbeats.
-- A row is stale when now() - ran_at > max_age_min minutes; null = no rule (event-driven rows such as instantly_webhook).
-- Heartbeats live in the same table (no new table): name 'hb:<side>:<process>', e.g. hb:simas:watch_replies, hb:benas:alarms.
-- Simas's Mac writes them with crm.beat(); Benas's side with crm-api `beat`, which only writes its own key's side.
alter table public.sync_status add column if not exists max_age_min int;
comment on column public.sync_status.max_age_min is
  'minutes after ran_at before this row counts as stale (crm-api health); null = no freshness rule. Heartbeats: hb:<side>:<process>';
-- writers' schedules: 10-min cloud syncs -> 25; slack-sync every 2 min -> 6; reply-tasks every 5 min -> 12; hourly jobs -> 90;
-- the panel_* jobs (two runs an hour) -> 45; client_metrics 07:45 + 19:45 -> 780; daily jobs -> 1500.
update public.sync_status s set max_age_min = v.m
  from (values ('replies', 25), ('sheet', 25), ('instantly', 25), ('interested', 90), ('slack', 6), ('reply_tasks', 12),
               ('deliveries', 90), ('campaigns_paused', 90), ('offer_reminders', 90), ('orders_rebuild', 1500),
               ('client_metrics', 780), ('panel_metrics', 45), ('panel_expenses', 45), ('panel_arms', 90), ('panel_ab_tests', 90),
               ('lead_campaigns', 1500), ('new_lead_target', 1500)) v(name, m)
 where s.name = v.name and s.max_age_min is null;

-- ============================================================ Part B (needs_attention reply rows)

-- B. needs_attention's 'reply' rows come from reply_wait() (through reply_wait_read()), the same source as the reply tasks, the
-- To-dos board and crm-api `unhandled`. Before this, the branch had its own looser filter (no auto-reply / hard-pass check, no
-- lost / snoozed check, no "we already wrote after it" check), so crm.py queue/recap and the CRM's "replies waiting" counted
-- replies nobody needs to answer. Every other branch is copied unchanged from crm_ops7.sql; columns, names and types are the same.
-- Rollback: re-run the needs_attention block of crm_ops7.sql.
create or replace view public.needs_attention as
  select 'reply'::text as kind, w.lead_email, w.name, coalesce(w.owner, '') as owner, w.inbox,
         w.received_at as due_at, w.snippet as detail
    from public.reply_wait_read() w
  union all
  select 'overdue', p.email, p.name, p.owner, p.inbox, p.next_action_at, p.next_action
    from public.pipeline p
   where p.next_action_at < now() and coalesce(p.status,'') not in ('WON','LOST','SILENT','DONE')
     and coalesce(p.fu_stage,'') in ('', 'none')          -- leads on the cadence show as 'followup' instead
  union all
  select 'no_next', p.email, p.name, p.owner, p.inbox, null, p.status
    from public.pipeline p
   where coalesce(p.next_action,'') = '' and coalesce(p.status,'') not in ('WON','LOST','SILENT','DONE')
     and coalesce(p.fu_stage,'') in ('', 'none')
  union all
  select 'promise', x.lead_email, p.name, x.owner, p.inbox, x.due_at, x.promise
    from public.promises x left join public.pipeline p on p.email = x.lead_email
   where x.status = 'open' and x.due_at < now()
  union all
  select 'paid_waiting', pay.email, c.name, coalesce(p.owner, ''), p.inbox, pay.paid_at,
         'paid $' || pay.amount::int || coalesce(' · ' || pay.package, '') ||
         case when exists (select 1 from public.deliveries d0 where d0.client_id = pay.client_id)
              then ', nothing delivered since' else ', deliveries not indexed: check their Drive folder' end
    from public.payments pay left join public.clients c on c.id = pay.client_id
         left join public.pipeline p on p.email = lower(pay.email)
   where not pay.refunded and pay.paid_at > now() - interval '10 days' and pay.paid_at < now() - interval '48 hours'
     and not exists (select 1 from public.deliveries d where d.client_id = pay.client_id and d.delivered_at >= pay.paid_at)
  union all
  select 'brief', p.email, p.name, p.owner, p.inbox, p.yes_at, 'said yes, no brief form yet'
    from public.pipeline p
   where p.status in ('YES','CLAIMED') and p.yes_at < now() - interval '24 hours'
     and not exists (select 1 from public.briefs b where b.email = p.email and b.submitted_at >= p.yes_at - interval '2 hours')
  union all
  -- follow-up due today or earlier (never two touches inside 20 hours)
  select 'followup', f.email, f.name, f.owner, f.inbox, f.due_at,
         'follow-up ' || (f.touches_done + 1) || ' of ' || f.touches_total || ' · ' || replace(f.fu_stage, '_', ' ') ||
         coalesce(' · they said: ' || left(f.fu_note, 120), '')
    from public.fu_state f
   where f.state = 'active' and f.due_at < (date_trunc('day', now() at time zone 'Europe/Vilnius') + interval '1 day') at time zone 'Europe/Vilnius'
     and (f.last_out is null or f.last_out < now() - interval '20 hours')
  union all
  -- both touches sent and no answer: park it (crm.py roll does this)
  select 'followup_done', f.email, f.name, f.owner, f.inbox, f.reengage_at,
         'both follow-ups sent, no answer: park until ' || to_char(f.reengage_at at time zone 'Europe/Vilnius', 'DD Mon')
    from public.fu_state f where f.state = 'finished' and f.fu_stage <> 'parked';
alter view public.needs_attention set (security_invoker = on);

-- ============================================================ after the crm-api deploy (hand step, key owner)
-- Give a key the new actions (same pattern as crm_orders2.sql / crm_tasks_live1.sql):
--   update public.api_keys set actions = array(select distinct unnest(actions || array['unhandled','health','beat']))
--    where name = 'benas-claude';
--
-- Needs Benas's go (write action, 11-22): task_move moves a founder card on the To-dos board (owner / status / note), the same
-- write as a drag on the board. No table change; only the two Claude keys get it:
--   update public.api_keys set actions = array(select distinct unnest(actions || array['task_move']))
--    where name in ('benas-claude', 'simas-claude');
