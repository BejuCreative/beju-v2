-- 11-23 (SIMAS): sample delivery emails send themselves 30 min after they're ready unless a founder sends, edits or sends them back.
alter table public.drafts add column if not exists auto_send_at timestamptz;
CREATE OR REPLACE FUNCTION public.drafts_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare founder text; sys boolean := not public.drafts_founder(); auto_ok boolean; fix_ok boolean;
begin
  new.body_sha256 := encode(sha256(convert_to(new.body, 'UTF8')), 'hex');
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then raise exception 'a new draft starts as pending'; end if;
    new.approved_sha256 := null; new.decided_by := null; new.decided_at := null;
    new.auto_send_at := case when new.category = 'sample' then now() + interval '30 minutes' end;   -- 11-23 SIMAS: a sample email sends itself after 30 min untouched
    return new;
  end if;
  -- who / where / to whom never changes after the draft is written (the approval covers all of it)
  if (new.lead_email, new.inbox, new.reply_to_id, new.to_email, new.cc_list, new.created_by, new.created_at)
     is distinct from (old.lead_email, old.inbox, old.reply_to_id, old.to_email, old.cc_list, old.created_by, old.created_at) then
    raise exception 'draft % : lead, inbox, thread and recipients are fixed once written (make a new draft)', old.id;
  end if;
  if old.status in ('sent', 'rejected') then raise exception 'draft % is % and final', old.id, old.status; end if;
  -- 11-23 (SIMAS): the two system moves of a sample delivery email
  --   auto_ok: 30 min passed with no founder action -> the sender's run approves the exact text as it stands
  --   fix_ok:  a founder sent it back ("What to change"); Claude saved the fix -> pending again, a fresh 30 min
  auto_ok := sys and old.category = 'sample' and old.status = 'pending' and new.status = 'approved' and old.auto_send_at is not null
             and old.auto_send_at <= now() and new.body is not distinct from old.body and new.approved_sha256 = new.body_sha256;
  fix_ok := sys and old.category = 'sample' and old.status = 'held' and new.status = 'pending';
  if auto_ok then new.decided_by := 'auto: 30 min, no founder change'; new.decided_at := now(); new.auto_send_at := null; return new; end if;
  if fix_ok then new.approved_sha256 := null; new.founder_note := null; new.decided_by := null; new.decided_at := null;
    new.auto_send_at := now() + interval '30 minutes'; return new; end if;
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
  if new.category = 'sample' then   -- 11-23: the 30-min clock runs only while the email waits untouched
    if new.status <> 'pending' then new.auto_send_at := null;
    elsif new.body is distinct from old.body or old.status <> 'pending' then new.auto_send_at := now() + interval '30 minutes'; end if;
  end if;
  return new;
end $function$
;
create or replace function public.draft_auto_approve() returns integer
language sql security definer set search_path = public, pg_temp as $$
  with x as (update public.drafts set status = 'approved', approved_sha256 = encode(sha256(convert_to(body, 'UTF8')), 'hex')
              where category = 'sample' and status = 'pending' and auto_send_at <= now() returning id)
  select count(*)::int from x;
$$;
revoke execute on function public.draft_auto_approve() from public, anon, authenticated;
create or replace view public.drafts_waiting as
 SELECT id, lead_email, inbox, to_email, cc_list, lead_last_snippet, category, reason, warnings, body, body_sha256, status, created_by, created_at,
    decided_by, decided_at, founder_note, reminders, error, round(EXTRACT(epoch FROM now() - created_at) / 60::numeric)::integer AS waiting_min, auto_send_at
   FROM drafts d
  WHERE status = ANY (ARRAY['pending'::text, 'held'::text, 'approved'::text, 'sending'::text, 'failed'::text, 'stale'::text, 'unknown'::text])
  ORDER BY created_at;
alter publication supabase_realtime add table public.drafts;   -- 11-23: Samples tab live drafts
