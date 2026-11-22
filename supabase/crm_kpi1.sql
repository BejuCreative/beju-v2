-- crm_kpi1.sql (Simas's Claude, 2026-11-22). SIMAS: "track those metrics in the crm": (1) new leads pushed per day, (2) sample -> paid rate.
-- Re-run safe. Days are Vilnius days.
--   kpi_daily: one row per day. leads_pushed = growth of the total lead count across all Instantly campaigns (campaign_live, kept fresh every
--   10 min by the instantly-sync cloud job), so pushes from BOTH sides count with no change to any push script. It starts on the first tracked
--   day (no history of totals exists before). leads_contacted = Instantly first emails that day (campaign_daily.new_leads).
--   kpi_sample_conversion: free samples delivered per week and how many of them paid (a payment from that email after delivery, a paid note on
--   the pipeline row, or status WON). Young weeks are still maturing: most buyers pay within 1-14 days of the sample.

create table if not exists public.kpi_daily (
  day date primary key,
  leads_total_eod int,
  leads_pushed int,
  leads_contacted int,
  samples_yes int,
  samples_delivered int,
  payments_n int,
  revenue numeric,
  updated_at timestamptz not null default now()
);
alter table public.kpi_daily enable row level security;
drop policy if exists "founders read" on public.kpi_daily;
create policy "founders read" on public.kpi_daily for select using (public.is_admin());
revoke all on public.kpi_daily from anon, authenticated;
grant select on public.kpi_daily to authenticated;

create or replace function public.kpi_daily_refresh() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare d date := (now() at time zone 'Europe/Vilnius')::date; tot int; prev int;
begin
  select coalesce(sum(leads_total), 0) into tot from public.campaign_live;
  select leads_total_eod into prev from public.kpi_daily where day = d - 1;
  insert into public.kpi_daily (day, leads_total_eod, leads_pushed, updated_at)
  values (d, tot, case when prev is null then null else greatest(tot - prev, 0) end, now())
  on conflict (day) do update set leads_total_eod = excluded.leads_total_eod, leads_pushed = excluded.leads_pushed, updated_at = now();
  -- history rows (no lead totals before tracking started) so the other columns have a timeline
  insert into public.kpi_daily (day) select g::date from generate_series(date '2026-10-01', d - 1, interval '1 day') g on conflict (day) do nothing;
  update public.kpi_daily k set
    leads_contacted   = (select coalesce(sum(c.new_leads), 0) from public.campaign_daily c where c.day = k.day),
    samples_yes       = (select count(*) from public.pipeline p where (p.yes_at at time zone 'Europe/Vilnius')::date = k.day),
    samples_delivered = (select count(*) from public.pipeline p where (p.delivered_at at time zone 'Europe/Vilnius')::date = k.day),
    payments_n        = (select count(*) from public.payments y where not coalesce(y.refunded, false) and (y.paid_at at time zone 'Europe/Vilnius')::date = k.day),
    revenue           = (select coalesce(sum(y.amount), 0) from public.payments y where not coalesce(y.refunded, false) and (y.paid_at at time zone 'Europe/Vilnius')::date = k.day),
    updated_at = now()
  where k.day >= d - 60;
end $$;
revoke execute on function public.kpi_daily_refresh() from public, anon, authenticated;

create or replace view public.kpi_sample_conversion with (security_invoker = on) as
with s as (
  select p.email, p.delivered_at,
         (p.paid is not null or p.status = 'WON'
          or exists (select 1 from public.payments y where lower(y.email) = lower(p.email) and not coalesce(y.refunded, false)
                       and y.paid_at >= p.delivered_at - interval '1 day')) as paid
    from public.pipeline p where p.delivered_at is not null
)
select date_trunc('week', s.delivered_at at time zone 'Europe/Vilnius')::date as week_start,
       count(*) as delivered,
       count(*) filter (where s.paid) as paid,
       round(100.0 * count(*) filter (where s.paid) / nullif(count(*), 0), 1) as paid_pct
  from s group by 1 order by 1 desc;
revoke all on public.kpi_sample_conversion from anon, authenticated;
grant select on public.kpi_sample_conversion to authenticated;

select cron.unschedule('kpi-daily') where exists (select 1 from cron.job where jobname = 'kpi-daily');
select cron.schedule('kpi-daily', '3-59/10 * * * *', $$select public.kpi_daily_refresh()$$);
