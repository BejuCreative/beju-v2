-- crm_drafts1.sql (Benas's side, 11-21; v2 after Simas's Claude's review 17:37): founder approval for lane-3 replies
-- (BENAS 17:2x: big deals + scopes, client problems, new terms, big names). A Claude writes a DRAFT; only a founder (CRM
-- login with 2-step = is_admin(), through the API gateway) can approve it, and the approval covers the exact text the
-- founder saw; a plain sender (draft-sender, no AI) claims an approved draft atomically, sends only that text, from the
-- inbox and to the recipients stored at draft time, and only if the thread hasn't moved. No founder answer = it waits.
-- Statuses: pending -> (held | rejected | approved) ; approved -> sending (the sender's claim) -> sent | failed | unknown | stale
--   sending -> approved only to release a claim the sender couldn't use (e.g. Instantly busy).
--   failed / stale (known NOT sent) can be re-approved by a founder; unknown (the send result is unclear) can only be
--   closed by a founder (rejected) after checking Instantly, never re-approved: no double send.
-- ADDITIVE ONLY. Rollback: drop the 2 triggers, 3 functions, the view and the table.

create table if not exists public.drafts (
  id                 bigint generated always as identity primary key,
  lead_email         text not null check (lead_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  inbox              text not null check (inbox ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),   -- the eaccount it goes out from
  reply_to_id        text not null,                -- the thread's LATEST email id when the draft was written
  to_email           text not null,                -- who the reply goes to (the lead's latest email's sender)
  cc_list            text[] not null default '{}', -- everyone else kept on the reply (never our own addresses)
  lead_last_snippet  text,                         -- what the lead last wrote, shown next to the draft
  category           text not null check (category in ('big_deal', 'client_problem', 'new_terms', 'big_name', 'other')),
  reason             text check (reason is null or char_length(reason) <= 500),
  warnings           text[] not null default '{}', -- lint / layout / hard-pass flags found when drafting
  body               text not null check (char_length(body) between 1 and 8000),
  body_sha256        text not null default '',     -- set by the trigger
  status             text not null default 'pending'
                     check (status in ('pending', 'held', 'approved', 'rejected', 'sending', 'sent', 'stale', 'failed', 'unknown')),
  created_by         text not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  decided_by         text,
  decided_at         timestamptz,
  approved_sha256    text,                         -- the founder's screen text fingerprint; must equal body_sha256
  founder_note       text check (founder_note is null or char_length(founder_note) <= 1000),
  reminders          int not null default 0,
  last_reminded_at   timestamptz,
  sent_at            timestamptz,
  sent_email_id      text,
  error              text
);
create index if not exists drafts_open_idx on public.drafts (status, created_at) where status in ('pending', 'held', 'approved', 'sending');
-- one open draft per lead: two approved drafts can never both go out
create unique index if not exists drafts_one_open_per_lead on public.drafts (lower(lead_email)) where status in ('pending', 'held', 'approved', 'sending');

alter table public.drafts enable row level security;
drop policy if exists "founders read" on public.drafts;
create policy "founders read" on public.drafts for select using (public.is_admin());
drop policy if exists "founders decide" on public.drafts;
create policy "founders decide" on public.drafts for update using (public.is_admin()) with check (public.is_admin());
revoke all on public.drafts from anon, authenticated;
grant select on public.drafts to authenticated;
grant update (status, body, founder_note, approved_sha256) on public.drafts to authenticated;   -- decide / edit only

-- A founder action = a real logged-in founder with 2-step, coming through the API gateway (not a direct DB login).
create or replace function public.drafts_founder() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_admin() and session_user = 'authenticator' and coalesce(auth.role(), '') = 'authenticated'
$$;

create or replace function public.drafts_guard() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare founder text; sys boolean := not public.drafts_founder();
begin
  new.body_sha256 := encode(sha256(convert_to(new.body, 'UTF8')), 'hex');
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then raise exception 'a new draft starts as pending'; end if;
    new.approved_sha256 := null; new.decided_by := null; new.decided_at := null;
    return new;
  end if;
  -- who / where / to whom never changes after the draft is written (the approval covers all of it)
  if (new.lead_email, new.inbox, new.reply_to_id, new.to_email, new.cc_list, new.created_by, new.created_at)
     is distinct from (old.lead_email, old.inbox, old.reply_to_id, old.to_email, old.cc_list, old.created_by, old.created_at) then
    raise exception 'draft % : lead, inbox, thread and recipients are fixed once written (make a new draft)', old.id;
  end if;
  if old.status in ('sent', 'rejected') then raise exception 'draft % is % and final', old.id, old.status; end if;
  if old.status = 'sending' and not sys then raise exception 'draft % is being sent right now; wait a minute', old.id; end if;
  if new.body is distinct from old.body and old.status not in ('pending', 'held') then
    if old.status = 'approved' and not sys then new.status := 'pending'; new.approved_sha256 := null;   -- founder edit: approve again
    else raise exception 'draft % can only be edited while pending or held', old.id; end if;
  end if;
  if new.status is distinct from old.status then
    if new.status in ('approved', 'held', 'rejected', 'pending') and not (old.status = 'sending' and new.status = 'approved' and sys) then
      if sys then raise exception 'only a founder can set a draft to %', new.status; end if;
      if old.status = 'unknown' and new.status <> 'rejected' then
        raise exception 'draft % may have been sent; check Instantly, then close it (rejected). It cannot be re-approved.', old.id;
      end if;
      if new.status = 'approved' then
        if old.status not in ('pending', 'held', 'failed', 'stale') then raise exception 'cannot approve from %', old.status; end if;
        if new.approved_sha256 is null or new.approved_sha256 <> new.body_sha256 then
          raise exception 'the text changed since you looked at it; reload and approve again';
        end if;
      else
        new.approved_sha256 := null;
      end if;
      select coalesce(nullif(name, ''), email) into founder from public.profiles where id = auth.uid();
      new.decided_by := founder; new.decided_at := now();
    elsif new.status = 'sending' then
      if not sys or old.status <> 'approved' or old.approved_sha256 is distinct from new.body_sha256 then
        raise exception 'only the sender can claim an approved, unchanged draft';
      end if;
    elsif new.status in ('sent', 'failed', 'unknown', 'stale') then
      if not sys or old.status <> 'sending' then raise exception 'only the sender, after claiming, can set %', new.status; end if;
    end if;
  elsif new.approved_sha256 is distinct from old.approved_sha256 then
    raise exception 'approved_sha256 changes only together with a status change';
  end if;
  return new;
end $$;
drop trigger if exists drafts_guard on public.drafts;
create trigger drafts_guard before insert or update on public.drafts for each row execute function public.drafts_guard();
revoke execute on function public.drafts_guard(), public.drafts_founder() from public, anon, authenticated;

-- history of every change (Simas's audit_row, same as desk_items / founder_tasks)
drop trigger if exists audit on public.drafts;
create trigger audit after insert or update or delete on public.drafts for each row execute function public.audit_row('id');

-- the sender's atomic claim: one draft, only if approved and the text is still the approved text
create or replace function public.draft_claim(p_id bigint) returns public.drafts
language sql security definer set search_path = public, pg_temp as $$
  update public.drafts set status = 'sending'
   where id = p_id and status = 'approved' and approved_sha256 = encode(sha256(convert_to(body, 'UTF8')), 'hex')
  returning *;
$$;
revoke execute on function public.draft_claim(bigint) from public, anon, authenticated;

-- What the CRM list and the reminders read: waiting drafts, oldest first, with how long they've waited.
create or replace view public.drafts_waiting with (security_invoker = on) as
select d.id, d.lead_email, d.inbox, d.to_email, d.cc_list, d.lead_last_snippet, d.category, d.reason, d.warnings, d.body,
       d.body_sha256, d.status, d.created_by, d.created_at, d.decided_by, d.decided_at, d.founder_note, d.reminders, d.error,
       round(extract(epoch from (now() - d.created_at)) / 60)::int waiting_min
from public.drafts d where d.status in ('pending', 'held', 'approved', 'sending', 'failed', 'stale', 'unknown')
order by d.created_at;
revoke all on public.drafts_waiting from anon, authenticated;
grant select on public.drafts_waiting to authenticated;

-- the one task list also shows what waits for a founder (review 11-21: "drafts waiting don't show in task_queue")
create or replace view public.task_queue with (security_invoker = on) as
select 'task' kind, t.id::text id, t.title, t.detail, t.owner, t.status, t.due_at, t.lead_email, t.source, t.big, t.pos,
       t.claimed_by, (t.claim_expires_at > now()) claimed, t.created_by, t.created_at
from public.tasks t where t.status in ('todo', 'doing')
union all
select 'promise', p.id::text, p.promise, null, coalesce(p.owner, 'Both'), 'todo', p.due_at, p.lead_email, 'promise', false, 0::double precision,
       null, false, p.created_by, p.created_at
from public.promises p where p.status = 'open'
union all
select 'approval', d.id::text, format('Approve the reply to %s (%s)', d.lead_email, replace(d.category, '_', ' ')), d.reason, 'Both',
       case when d.status = 'held' then 'doing' else 'todo' end, null, d.lead_email, 'approval', true, 0::double precision,
       null, false, d.created_by, d.created_at
from public.drafts d where d.status in ('pending', 'held', 'unknown');
revoke all on public.task_queue from anon, authenticated;
grant select on public.task_queue to authenticated;
