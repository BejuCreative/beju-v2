-- crm_notify2.sql (11-21): every crm_tg_* trigger function gets an exception guard, so a bug in an event builder can
-- never fail the payment / reply / sync / page write it sits on (crm_event_add already guarded the insert itself).
-- Same logic as crm_notify1.sql, crm_touch2.sql and crm_slack1.sql. Rollback: re-run those files' crm_tg_* definitions.

create or replace function public.crm_tg_payment() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_payment(new);
  return null;
exception when others then
  raise warning 'crm_tg_payment skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_payment() from public, anon, authenticated;

create or replace function public.crm_tg_call() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then perform public.crm_ev_call(new, coalesce(new.status, '') = 'cancelled');
  elsif coalesce(new.status, '') = 'cancelled' and coalesce(old.status, '') <> 'cancelled' then perform public.crm_ev_call(new, true);
  end if;
  return null;
exception when others then
  raise warning 'crm_tg_call skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_call() from public, anon, authenticated;

create or replace function public.crm_tg_reply() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and old.received_at is not distinct from new.received_at and old.kind is not distinct from new.kind then return null; end if;
  perform public.crm_ev_reply(new);
  return null;
exception when others then
  raise warning 'crm_tg_reply skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_reply() from public, anon, authenticated;

create or replace function public.crm_tg_interested() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_interested(new);
  return null;
exception when others then
  raise warning 'crm_tg_interested skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_interested() from public, anon, authenticated;

create or replace function public.crm_tg_sample() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_sample(new);
  return null;
exception when others then
  raise warning 'crm_tg_sample skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_sample() from public, anon, authenticated;

create or replace function public.crm_tg_stage() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_stage(new);
  return null;
exception when others then
  raise warning 'crm_tg_stage skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_stage() from public, anon, authenticated;

create or replace function public.crm_tg_desk() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind = 'hold' then
    if tg_op = 'INSERT' and new.status = 'open' then perform public.crm_ev_desk(new, 'hold');
    elsif tg_op = 'UPDATE' and old.status = 'open' and new.status = 'closed' then perform public.crm_ev_desk(new, 'lifted');
    end if;
  elsif new.kind = 'production' and new.status = 'open' and new.stage = 'founder_check'
        and (tg_op = 'INSERT' or old.stage is distinct from 'founder_check' or old.status is distinct from 'open') then
    perform public.crm_ev_desk(new, 'founder_check');
  end if;
  return null;
exception when others then
  raise warning 'crm_tg_desk skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_desk() from public, anon, authenticated;

create or replace function public.crm_tg_task() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_task(new);
  return null;
exception when others then
  raise warning 'crm_tg_task skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_task() from public, anon, authenticated;

create or replace function public.crm_tg_touch() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_touch(new);
  return null;
exception when others then
  raise warning 'crm_tg_touch skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_touch() from public, anon, authenticated;

create or replace function public.crm_tg_slack() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.crm_ev_slack(new);
  return null;
exception when others then
  raise warning 'crm_tg_slack skipped: %', sqlerrm;   -- the event is lost, the business write is not
  return null;
end $$;
revoke all on function public.crm_tg_slack() from public, anon, authenticated;
