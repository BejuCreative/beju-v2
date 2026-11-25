-- crm_approvals1.sql (Benas's Claude, 2026-11-25): ONE approvals queue for both founders and both Claudes.
-- WHY: BENAS 11-25 "both Claudes send the approvals to one tab, and they send notifications for everything they need an approval
--   or an okay to commit or to do ... so one of us can approve something that the other Claude has pinged."
--   A Claude (benas-claude / simas-claude) asks for an OK (a decision, or an email it wants to send); either founder decides in the
--   CRM Approvals tab; the decision is logged (who, when, note); the asking Claude reads it back (crm-api approval_get / approvals)
--   and acts, then marks it done (approval_done).
-- DESIGN
--   * kind 'decision' = any OK / go-ahead the Claude needs. kind 'email' = an email the Claude wants to send: when it was written
--     with crm-api draft_create, draft_id points at the draft and the existing draft flow does the deciding and the sending
--     (drafts_guard + draft-sender are NOT touched); a trigger below copies that draft's outcome into this row.
--   * Founders decide only through approval_decide() (a security-definer function that checks drafts_founder(): a signed-in founder with
--     2-step through the API gateway, the same test as the drafts). There is no direct UPDATE grant on the table.
--   * needs_both: stays 'pending' until BOTH founders approved (decided_uids / decided_by show who so far: "1 of 2").
--   * Inserts, approval_done and approval_cancel come from the service role (crm-api, the Claude's own key).
--   * Notifications: a trigger writes a push_outbox row (new event 'approval', title "Needs your OK"; push-send sends it to every
--     device that has the event on). New waiting reply drafts notify the same way. approvals_remind() re-notifies a still-pending
--     item at 1 h and 3 h (pg_cron block at the bottom). Every trigger body is wrapped in `exception when others`: a notification
--     never blocks a write.
-- NEEDS crm_push1.sql (push_outbox, push_subs, push_first) and crm_drafts1.sql (drafts, drafts_founder, audit_row) applied first.
-- ADDITIVE except 3 deliberate widenings: push_outbox.event and push_subs.events accept 'approval', and existing push_subs get
--   'approval' appended (so every phone that already has notifications on also gets this one; each phone can switch it off).
-- APPLY ORDER: 1) this file, 2) deploy crm-api + push-send, 3) the cron block at the bottom. Rollback: bottom of the file.
begin;

-- ---------------------------------------------------------------- the queue
create table if not exists public.approvals (
  id               bigint generated always as identity primary key,
  kind             text not null check (kind in ('email', 'decision')),
  title            text not null check (char_length(title) between 1 and 200),         -- the one-line question
  why              text check (why is null or char_length(why) <= 2000),
  recommendation   text check (recommendation is null or char_length(recommendation) <= 2000),
  body             text check (body is null or char_length(body) <= 8000),              -- the full email text, or the detail
  lead_email       text check (lead_email is null or lead_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  client_name      text check (client_name is null or char_length(client_name) <= 200),
  inbox            text check (inbox is null or inbox ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  draft_id         bigint,                                                              -- email approvals made with draft_create: public.drafts.id
  links            jsonb not null default '[]'::jsonb check (jsonb_typeof(links) = 'array' and jsonb_array_length(links) <= 10),
  requested_by     text not null check (requested_by in ('benas-claude', 'simas-claude')),
  urgency          text not null default 'routine' check (urgency in ('money', 'client', 'routine')),
  needs_both       boolean not null default false,
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'held', 'done', 'cancelled')),
  decided_by       text[] not null default '{}',                                        -- founder names, in the order they approved / decided
  decided_uids     uuid[] not null default '{}',                                        -- the same founders' ids (a "both" approval = 2 different ids)
  decided_at       timestamptz,
  note             text check (note is null or char_length(note) <= 2000),              -- the founder's note (No + note, Hold, approve with a note)
  edited_body      text check (edited_body is null or char_length(edited_body) <= 8000),
  acted_at         timestamptz,                                                         -- the Claude marked it done (approval_done)
  reminded_1h_at   timestamptz,
  reminded_3h_at   timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists approvals_open_idx on public.approvals (status, created_at) where status in ('pending', 'held');
create index if not exists approvals_draft_idx on public.approvals (draft_id) where draft_id is not null;
create index if not exists approvals_decided_idx on public.approvals (decided_at) where decided_at is not null;

alter table public.approvals enable row level security;
drop policy if exists "founders read" on public.approvals;
create policy "founders read" on public.approvals for select using (public.is_admin());
revoke all on public.approvals from anon, authenticated;
grant select on public.approvals to authenticated;
-- No policy and no grant for insert / update / delete: the service role (crm-api) writes new rows, approval_decide() records a founder's answer.

-- fixed fields never change; a finished row stays finished
create or replace function public.approvals_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.status := 'pending'; new.decided_by := '{}'; new.decided_uids := '{}'; new.decided_at := null; new.note := null; new.edited_body := null;
    new.acted_at := null; new.reminded_1h_at := null; new.reminded_3h_at := null;
    return new;
  end if;
  if (new.kind, new.title, new.why, new.recommendation, new.body, new.lead_email, new.client_name, new.inbox, new.draft_id, new.links,
      new.requested_by, new.urgency, new.needs_both, new.created_at)
     is distinct from (old.kind, old.title, old.why, old.recommendation, old.body, old.lead_email, old.client_name, old.inbox, old.draft_id, old.links,
      old.requested_by, old.urgency, old.needs_both, old.created_at) then
    raise exception 'approval %: the question is fixed once asked (make a new approval)', old.id;
  end if;
  if old.status in ('done', 'cancelled') and new.status is distinct from old.status then raise exception 'approval % is % and final', old.id, old.status; end if;
  return new;
end $$;
drop trigger if exists approvals_guard on public.approvals;
create trigger approvals_guard before insert or update on public.approvals for each row execute function public.approvals_guard();
revoke execute on function public.approvals_guard() from public, anon, authenticated;

-- history of every change = the decision log (who decided what, when): same audit as drafts / desk_items
drop trigger if exists audit on public.approvals;
create trigger audit after insert or update or delete on public.approvals for each row execute function public.audit_row('id');

-- live updates: a decision by one founder shows on the other's phone (the CRM listens on this table)
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'approvals') then
    alter publication supabase_realtime add table public.approvals;
  end if;
exception when others then raise notice 'approvals not added to the realtime publication: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------- a founder decides
-- p_action: approve | reject | hold. reject needs a note. approve may carry a note and / or an edited text.
-- needs_both: the first approval keeps the row 'pending' (decided_by = the one who approved); the second, from a DIFFERENT founder, approves it.
-- Any founder's reject ends it at once. An email with a live draft is decided through the draft (its own approve / send flow), not here.
create or replace function public.approval_decide(p_id bigint, p_action text, p_note text default null, p_edited_body text default null)
returns public.approvals
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.approvals; nm text; uid uuid := auth.uid(); n text := nullif(btrim(coalesce(p_note, '')), ''); eb text := nullif(btrim(coalesce(p_edited_body, '')), '');
begin
  if not public.drafts_founder() then raise exception 'founders only (sign in with your 2-step login)' using errcode = '42501'; end if;
  if p_action not in ('approve', 'reject', 'hold') then raise exception 'action must be approve, reject or hold'; end if;
  if p_action = 'reject' and n is null then raise exception 'say why in a note: Claude reads it'; end if;
  select * into r from public.approvals where id = p_id for update;
  if not found then raise exception 'no approval %', p_id; end if;
  if r.status not in ('pending', 'held') then raise exception 'approval % is already % (nothing to decide)', p_id, r.status; end if;
  if r.draft_id is not null and exists (select 1 from public.drafts d where d.id = r.draft_id and d.status in ('pending', 'held', 'approved', 'sending', 'failed', 'stale', 'unknown')) then
    raise exception 'this approval is an email draft: decide it with the draft buttons (approve and send / edit / hold / reject)';
  end if;
  select coalesce(nullif(btrim(name), ''), email, 'a founder') into nm from public.profiles where id = uid;
  nm := coalesce(nm, 'a founder');
  if p_action = 'approve' then
    if uid = any (r.decided_uids) then raise exception 'you already approved this; it waits for the other founder'; end if;
    update public.approvals set
        decided_uids = array_append(decided_uids, uid), decided_by = array_append(decided_by, nm),
        status = case when needs_both and cardinality(array_append(decided_uids, uid)) < 2 then 'pending' else 'approved' end,
        decided_at = now(), note = coalesce(n, note), edited_body = coalesce(eb, edited_body)
      where id = p_id returning * into r;
  elsif p_action = 'reject' then
    update public.approvals set status = 'rejected', decided_by = array_append(decided_by, nm), decided_uids = array_append(decided_uids, uid), decided_at = now(), note = n
      where id = p_id returning * into r;
  else
    update public.approvals set status = 'held', decided_at = now(), note = coalesce(n, note)
      where id = p_id returning * into r;
  end if;
  return r;
end $$;
revoke all on function public.approval_decide(bigint, text, text, text) from public, anon;
grant execute on function public.approval_decide(bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------- an email approval follows its draft
-- The founder approves / holds / rejects the draft in the CRM (drafts_guard enforces everything); this copies the outcome into the linked
-- approval so the asking Claude sees one status, and marks it done when the draft is sent.
create or replace function public.approvals_follow_draft() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status is distinct from old.status then
      update public.approvals a set
          status = case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' when 'held' then 'held' when 'sent' then 'done' when 'pending' then 'pending' else a.status end,
          decided_by = case when new.status in ('approved', 'rejected', 'held') and new.decided_by is not null then array[new.decided_by] when new.status = 'pending' then '{}' else a.decided_by end,
          decided_at = case when new.status in ('approved', 'rejected', 'held') then coalesce(new.decided_at, now()) when new.status = 'pending' then null else a.decided_at end,
          note = case when new.status in ('approved', 'rejected', 'held') and new.founder_note is not null then new.founder_note else a.note end,
          acted_at = case when new.status = 'sent' then coalesce(new.sent_at, now()) else a.acted_at end
        where a.draft_id = new.id and a.status in ('pending', 'held', 'approved');
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists approvals_follow_draft on public.drafts;
create trigger approvals_follow_draft after update of status on public.drafts for each row execute function public.approvals_follow_draft();
revoke execute on function public.approvals_follow_draft() from public, anon, authenticated;

-- ---------------------------------------------------------------- push: the new event 'approval'
alter table public.push_outbox drop constraint if exists push_outbox_event_check;
alter table public.push_outbox add constraint push_outbox_event_check check (event in ('money', 'reply', 'sample_yes', 'client_changes', 'approval'));
alter table public.push_subs drop constraint if exists push_subs_events_check;
alter table public.push_subs add constraint push_subs_events_check check (events <@ array['money', 'reply', 'sample_yes', 'client_changes', 'approval']);
alter table public.push_subs alter column events set default array['money', 'reply', 'sample_yes', 'client_changes', 'approval'];
update public.push_subs set events = array_append(events, 'approval') where not ('approval' = any (events));   -- existing phones get it too (each can switch it off)

-- the CRM saves a device through this function: same as crm_push1.sql with 'approval' in the default list
create or replace function public.push_sub_save(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null, p_events text[] default null)
returns public.push_subs
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.push_subs; nm text;
begin
  if not public.is_admin() then raise exception 'founders only' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'bad subscription'; end if;
  select name into nm from public.profiles where id = auth.uid();
  insert into public.push_subs as s (user_id, founder, endpoint, p256dh, auth, user_agent, events)
  values (auth.uid(), nm, p_endpoint, p_p256dh, p_auth, left(p_ua, 300), coalesce(p_events, array['money', 'reply', 'sample_yes', 'client_changes', 'approval']))
  on conflict (endpoint) do update set user_id = auth.uid(), founder = nm, p256dh = excluded.p256dh, auth = excluded.auth,
    user_agent = excluded.user_agent, events = coalesce(p_events, s.events), disabled_at = null, failed_count = 0
  returning * into r;
  return r;
end $$;
revoke all on function public.push_sub_save(text, text, text, text, text[]) from public, anon;
grant execute on function public.push_sub_save(text, text, text, text, text[]) to authenticated;

-- a new approval -> "Needs your OK". An email approval whose draft already notified (the draft trigger below) is not announced twice.
create or replace function public.push_on_approval() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status = 'pending' and not (new.draft_id is not null and exists (select 1 from public.push_outbox o where o.event = 'approval' and o.ref = 'draft:' || new.draft_id)) then
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('approval', 'approval:' || new.id, 'Needs your OK', left(new.title, 160), '?p=approvals&id=' || new.id, 'approval:' || new.id)
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_approval on public.approvals;
create trigger push_approval after insert on public.approvals for each row execute function public.push_on_approval();

-- a new reply draft that waits for a founder (the lanes a founder approves: big deals, client problems, new terms, big names, other).
-- Sample / client delivery drafts have their own board and a send timer: no push here.
create or replace function public.push_on_draft() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare nm text;
begin
  begin
    if new.status = 'pending' and new.category in ('big_deal', 'client_problem', 'new_terms', 'big_name', 'other') then
      select p.name into nm from public.pipeline p where lower(p.email) = lower(new.lead_email) limit 1;
      insert into public.push_outbox (event, ref, title, body, url, tag)
      values ('approval', 'draft:' || new.id, 'Needs your OK', 'Reply to ' || public.push_first(nm), '?p=approvals&id=d' || new.id, 'draft:' || new.id)
      on conflict (event, ref) do nothing;
    end if;
  exception when others then null;
  end;
  return null;
end $$;
drop trigger if exists push_draft on public.drafts;
create trigger push_draft after insert on public.drafts for each row execute function public.push_on_draft();
revoke execute on function public.push_on_approval(), public.push_on_draft() from public, anon, authenticated;

-- ---------------------------------------------------------------- reminders at 1 h and 3 h (a pure-SQL job: no secret needed)
-- Only 'pending' (not 'held': a hold is a decision to wait). Each step fires once: reminded_1h_at / reminded_3h_at for approvals, the
-- unique (event, ref) of the outbox for drafts (their Slack nudges stay in draft-sender). Returns how many reminders it queued.
create or replace function public.approvals_remind() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; k int;
begin
  begin
    with due as (update public.approvals set reminded_1h_at = now()
                  where status = 'pending' and reminded_1h_at is null and created_at < now() - interval '1 hour' and created_at > now() - interval '3 days' returning id, title)
    insert into public.push_outbox (event, ref, title, body, url, tag)
      select 'approval', 'approval:' || id || ':1h', 'Still needs your OK', left(title, 160), '?p=approvals&id=' || id, 'approval:' || id from due
      on conflict (event, ref) do nothing;
    get diagnostics k = row_count; n := n + k;
    with due as (update public.approvals set reminded_3h_at = now()
                  where status = 'pending' and reminded_3h_at is null and created_at < now() - interval '3 hours' and created_at > now() - interval '3 days' returning id, title)
    insert into public.push_outbox (event, ref, title, body, url, tag)
      select 'approval', 'approval:' || id || ':3h', 'Still waiting for your OK (3 h)', left(title, 160), '?p=approvals&id=' || id, 'approval:' || id from due
      on conflict (event, ref) do nothing;
    get diagnostics k = row_count; n := n + k;
    insert into public.push_outbox (event, ref, title, body, url, tag)
      select 'approval', 'draft:' || d.id || ':1h', 'Still needs your OK', 'A reply draft has waited an hour', '?p=approvals&id=d' || d.id, 'draft:' || d.id
        from public.drafts d where d.status = 'pending' and d.category in ('big_deal', 'client_problem', 'new_terms', 'big_name', 'other')
         and d.created_at < now() - interval '1 hour' and d.created_at > now() - interval '3 days'
      on conflict (event, ref) do nothing;
    get diagnostics k = row_count; n := n + k;
    insert into public.push_outbox (event, ref, title, body, url, tag)
      select 'approval', 'draft:' || d.id || ':3h', 'Still waiting for your OK (3 h)', 'A reply draft has waited 3 hours', '?p=approvals&id=d' || d.id, 'draft:' || d.id
        from public.drafts d where d.status = 'pending' and d.category in ('big_deal', 'client_problem', 'new_terms', 'big_name', 'other')
         and d.created_at < now() - interval '3 hours' and d.created_at > now() - interval '3 days'
      on conflict (event, ref) do nothing;
    get diagnostics k = row_count; n := n + k;
  exception when others then null;
  end;
  return n;
end $$;
revoke all on function public.approvals_remind() from public, anon, authenticated;
grant execute on function public.approvals_remind() to service_role;

-- ---------------------------------------------------------------- the two Claudes may use the new crm-api actions
update public.api_keys k set actions = (select array_agg(distinct a order by a) from unnest(k.actions || array['approval_add', 'approvals', 'approval_get', 'approval_done', 'approval_cancel']) a)
 where k.name in ('benas-claude', 'simas-claude') and k.revoked_at is null;

commit;

-- ---------------------------------------------------------------- cron (run AFTER the SQL above; no secret needed, it calls a SQL function)
-- select cron.unschedule('approvals-remind') where exists (select 1 from cron.job where jobname = 'approvals-remind');
-- select cron.schedule('approvals-remind', '*/5 * * * *', $$ select public.approvals_remind() $$);

-- ---------------------------------------------------------------- rollback
-- select cron.unschedule('approvals-remind');
-- begin;
-- drop trigger if exists push_approval on public.approvals;  drop function if exists public.push_on_approval();
-- drop trigger if exists push_draft on public.drafts;        drop function if exists public.push_on_draft();
-- drop trigger if exists approvals_follow_draft on public.drafts; drop function if exists public.approvals_follow_draft();
-- drop function if exists public.approvals_remind();
-- drop function if exists public.approval_decide(bigint, text, text, text);
-- delete from public.push_outbox where event = 'approval';
-- update public.push_subs set events = array_remove(events, 'approval');
-- alter table public.push_outbox drop constraint if exists push_outbox_event_check;
-- alter table public.push_outbox add constraint push_outbox_event_check check (event in ('money', 'reply', 'sample_yes', 'client_changes'));
-- alter table public.push_subs drop constraint if exists push_subs_events_check;
-- alter table public.push_subs add constraint push_subs_events_check check (events <@ array['money', 'reply', 'sample_yes', 'client_changes']);
-- alter table public.push_subs alter column events set default array['money', 'reply', 'sample_yes', 'client_changes'];
-- -- push_sub_save: re-run its definition from crm_push1.sql (default list without 'approval')
-- update public.api_keys set actions = array(select a from unnest(actions) a where a not in ('approval_add', 'approvals', 'approval_get', 'approval_done', 'approval_cancel'));
-- alter publication supabase_realtime drop table public.approvals;
-- drop table if exists public.approvals;
-- commit;
