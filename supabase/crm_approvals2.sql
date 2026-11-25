-- crm_approvals2.sql (Benas's Claude, 2026-11-25): keep the Approvals tab true without anyone remembering to tidy it.
-- WHY: BENAS 11-25 "will the approvals always be 100% accurate?" -> "build everything, go".
--   An item went stale when (a) it was settled in chat, (b) the Claude acted but forgot approval_done, or (c) the lead moved on
--   (wrote again, or someone already emailed them) while it waited. (a) is a Claude rule; this file handles (b) and (c):
--   * APPROVED + an email to that lead went out after the decision  -> status 'done' (acted_at = that send), note says so.
--   * PENDING / HELD + the lead wrote after it was asked             -> outdated_at + outdated_reason ("they wrote again at …").
--   * PENDING / HELD + we emailed the lead after it was asked        -> outdated (someone already answered; the Claude re-checks).
--   Outdated is a flag, not a decision: the founder still sees the card, with a warning not to approve blindly; the asking Claude
--   re-checks and cancels it or asks again (a question is fixed once asked).
-- Source of truth = public.threads (replies arrive by webhook within seconds; our own sends can lag up to ~1 h, so the Claude's hourly
--   self-check in approvals.py covers that gap).
-- ADDITIVE: two nullable columns + one function + one cron job. Rollback at the bottom.
begin;

alter table public.approvals add column if not exists outdated_at timestamptz;
alter table public.approvals add column if not exists outdated_reason text check (outdated_reason is null or char_length(outdated_reason) <= 300);

create or replace function public.approvals_reconcile() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; k int;
begin
  begin
    -- (b) approved, and an email to that lead went out after the decision: the Claude acted
    with sent as (
      select a.id, min(t.at) as at
        from public.approvals a join public.threads t on lower(t.lead_email) = lower(a.lead_email) and t.direction = 'out' and t.at > a.decided_at
       where a.status = 'approved' and a.lead_email is not null and a.decided_at is not null
       group by a.id)
    update public.approvals a
       set status = 'done', acted_at = s.at,
           note = left(concat_ws(E'\n', a.note, format('[auto] closed: an email to this lead went out %s (Vilnius) after the OK.',
                                                       to_char(s.at at time zone 'Europe/Vilnius', 'MM-DD HH24:MI'))), 2000)
      from sent s where a.id = s.id;
    get diagnostics k = row_count; n := n + k;

    -- (c) still waiting, and the thread moved since it was asked: flag it once (the newest reason wins if it moves again)
    with moved as (
      select a.id, t.direction, t.at,
             row_number() over (partition by a.id order by t.at desc) as rn
        from public.approvals a join public.threads t on lower(t.lead_email) = lower(a.lead_email) and t.at > a.created_at
       where a.status in ('pending', 'held') and a.lead_email is not null
         and not (a.draft_id is not null and t.direction = 'out'))          -- a linked draft's own send closes it via approvals_follow_draft
    update public.approvals a
       set outdated_at = m.at,
           outdated_reason = case m.direction
             when 'in' then format('The lead wrote again %s, after this was asked. Read the thread before deciding.', to_char(m.at at time zone 'Europe/Vilnius', 'MM-DD HH24:MI'))
             else format('An email already went to this lead %s, after this was asked. Claude is re-checking.', to_char(m.at at time zone 'Europe/Vilnius', 'MM-DD HH24:MI')) end
      from moved m
     where a.id = m.id and m.rn = 1 and a.outdated_at is distinct from m.at;
    get diagnostics k = row_count; n := n + k;

    insert into public.sync_status (name, ran_at, ok, detail) values ('approvals_reconcile', now(), true, n || ' approval(s) closed or flagged')
    on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  exception when others then
    insert into public.sync_status (name, ran_at, ok, detail) values ('approvals_reconcile', now(), false, left(sqlerrm, 200))
    on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  end;
  return n;
end $$;
revoke all on function public.approvals_reconcile() from public, anon, authenticated;
grant execute on function public.approvals_reconcile() to service_role;

commit;

-- ---------------------------------------------------------------- cron (run AFTER the SQL above; pure SQL, no secret)
-- select cron.unschedule('approvals-reconcile') where exists (select 1 from cron.job where jobname = 'approvals-reconcile');
-- select cron.schedule('approvals-reconcile', '*/5 * * * *', $$ select public.approvals_reconcile() $$);

-- ---------------------------------------------------------------- rollback
-- select cron.unschedule('approvals-reconcile');
-- drop function if exists public.approvals_reconcile();
-- alter table public.approvals drop column if exists outdated_reason, drop column if exists outdated_at;
