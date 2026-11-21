-- crm_orders3.sql (Benas's side, 11-21): fixes from Simas's Claude's review of #2/#3. Needs crm_orders1.sql.
-- PART A (hotfix): the order triggers must NEVER reject a payments / deliveries write. Any error becomes a warning and the
--   row is saved as usual; the nightly orders_rebuild_all() repairs whatever a trigger skipped.
-- PART B: "revised" is decided by VERSION (Drive dates have no time of day); revision_open problem; tighter folder regex;
--   view grants; pg_temp in search_path; rebuild_all guarded per folder and reported in sync_status.

-- ================================================================ PART A
create or replace function public.orders_from_payment() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record;
begin
  begin
    if not new.refunded then
      select * into s from public.order_size(new.package, new.amount);
      insert into public.orders (client_id, kind, shorts_bought, size_source, amount, currency, payment_id, opened_at, period_end)
      values (new.client_id, s.kind, s.n, s.src, new.amount, new.currency, new.id, new.paid_at, new.paid_at + interval '30 days')
      on conflict (payment_id) do nothing;
    end if;
  exception when others then
    raise warning 'orders_from_payment skipped payment %: %', new.id, sqlerrm;   -- never block the payment row
  end;
  return new;
end $$;

create or replace function public.orders_from_delivery() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare oid bigint;
begin
  begin
    oid := public.order_for_folder(new.client_id, new.order_name);
    if oid is not null then perform public.order_rebuild(oid); end if;
    if tg_op = 'UPDATE' and old.order_name is distinct from new.order_name then
      select id into oid from public.orders where client_id = old.client_id and folder = old.order_name;
      if oid is not null then perform public.order_rebuild(oid); end if;
    end if;
  exception when others then
    raise warning 'orders_from_delivery skipped file %: %', new.id, sqlerrm;    -- never block the Drive sync
  end;
  return new;
end $$;

-- ================================================================ PART B
-- 1) "revised" by VERSION: when a revision is logged, the API stores the version the client saw (revision_base_version);
--    revised = a newer version than that arrived. (deliveries.delivered_at is a date, so times can't decide it.)
drop view if exists public.order_problems;
drop view if exists public.order_progress;
alter table public.order_items add column if not exists revision_base_version int;
alter table public.order_items drop column if exists status;
alter table public.order_items add column status text generated always as (
  case when revision_asked_at is null then (case when last_version > 1 then 'revised' else 'delivered' end)
       when last_version > coalesce(revision_base_version, 1) then 'revised'
       else 'revision_requested' end) stored;

-- 2) folder rules: "\mtests?\M" (not "Testimonials"); pg_temp last in search_path
create or replace function public.order_for_folder(p_client uuid, p_folder text) returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare oid bigint; k int; fsize int; d timestamptz; m text[];
begin
  if p_client is null or p_folder is null then return null; end if;
  if p_folder ~* '(internal|\mtests?\M|sample|earlier versions|replaced)' then return null; end if;   -- never counts
  select id into oid from public.orders where client_id = p_client and folder = p_folder;
  if oid is not null then return oid; end if;
  fsize := (regexp_match(p_folder, '^\s*(\d+)[\s-]*(?:shorts?|short form|videos?|long form)', 'i'))[1]::int;
  d := coalesce((((regexp_match(p_folder, '(\d{4}-\d{2}-\d{2})'))[1]) || ' 12:00 Europe/Vilnius')::timestamptz, now());
  if p_folder ~* '·\s*referral\s*·' then
    insert into public.orders (client_id, kind, shorts_bought, size_source, opened_at, period_end, folder, created_by)
    values (p_client, 'referral', fsize, 'folder', d, d + interval '30 days', p_folder, 'orders_sync') returning id into oid;
    return oid;
  end if;
  m := regexp_match(p_folder, '·\s*(?:order|month)\s+(\d+)\s*·', 'i');
  if m is null then
    insert into public.orders (client_id, kind, shorts_bought, size_source, opened_at, folder, status, created_by)
    values (p_client, 'legacy', fsize, 'folder', d, p_folder, 'legacy', 'orders_sync') returning id into oid;
    return oid;
  end if;
  k := m[1]::int;
  if p_folder ~ '\d{4}-\d{2}-\d{2}' then
    select id into oid from public.orders
     where client_id = p_client and folder is null and kind in ('pack', 'monthly', 'long', 'custom')
       and abs((opened_at at time zone 'Europe/Vilnius')::date - d::date) <= 3
     order by abs((opened_at at time zone 'Europe/Vilnius')::date - d::date), opened_at limit 1;
  end if;
  if oid is null then
    select id into oid from (
      select id, folder, row_number() over (order by opened_at, id) rn
      from public.orders where client_id = p_client and kind in ('pack', 'monthly', 'long', 'custom')) o
    where rn = k and folder is null;
  end if;
  if oid is null then return null; end if;
  update public.orders set folder = p_folder, updated_at = now(),
         shorts_bought = coalesce(shorts_bought, fsize), size_source = coalesce(size_source, case when fsize is null then null else 'folder' end)
   where id = oid;
  return oid;
end $$;

-- 3) one bad file never blocks its order: Short numbers outside 1-1000 and files with no date are skipped (they show as problems)
create or replace function public.order_rebuild(p_order bigint) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o record;
begin
  select * into o from public.orders where id = p_order;
  if o.folder is null then return; end if;
  with f as (
    select d.id, d.title, d.delivered_at::timestamptz at, m.slot, coalesce(v.ver, 1) ver
    from public.deliveries d
    cross join lateral (select coalesce((regexp_match(d.title, '\m(?:short|reel)\s*(\d{1,4})\M', 'i'))[1],
                                        (regexp_match(d.title, '^\s*(\d{1,2})\s+\D'))[1])::int slot) m
    left join lateral (select coalesce(x[1], x[2])::int ver from regexp_match(d.title, '\mv(\d{1,3})\M|\(v(\d{1,3})\)', 'i') x) v on true
    where d.client_id = o.client_id and d.order_name = o.folder and d.title !~* '(\msample\M|\(clean\))'
      and m.slot between 1 and 1000 and d.delivered_at is not null
  ), g as (
    select slot, (array_agg(title order by ver desc, at desc))[1] title, min(at) first_at, max(ver) vmax,
           max(at) filter (where ver = (select max(ver) from f f2 where f2.slot = f.slot)) last_at, array_agg(id order by ver) ids
    from f group by slot
  )
  insert into public.order_items as i (order_id, slot, title, delivered_at, last_version, last_version_at, file_ids)
  select p_order, slot, title, first_at, vmax, last_at, ids from g
  on conflict (order_id, slot) do update
     set title = excluded.title, delivered_at = least(i.delivered_at, excluded.delivered_at), last_version = excluded.last_version,
         last_version_at = excluded.last_version_at, file_ids = excluded.file_ids, updated_at = now()
     where (i.title, i.last_version, i.last_version_at, i.file_ids) is distinct from
           (excluded.title, excluded.last_version, excluded.last_version_at, excluded.file_ids);
  delete from public.order_items i where i.order_id = p_order and i.revision_asked_at is null and i.posted_at is null
     and not exists (select 1 from public.deliveries d where d.id = any(i.file_ids) and d.order_name = o.folder);
  update public.orders set status = 'complete', updated_at = now()
   where id = p_order and status = 'open' and shorts_bought is not null
     and (select count(*) from public.order_items where order_id = p_order) >= shorts_bought;
end $$;

-- 4) the nightly run: one bad folder or payment never stops the rest; result goes to sync_status ("orders_rebuild")
create or replace function public.orders_rebuild_all() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare pay record; f record; n int := 0; bad int := 0; oid bigint; last_err text;
begin
  for pay in select * from public.payments where not refunded order by paid_at loop
    begin
      perform 1 from public.orders where payment_id = pay.id;
      if not found then
        insert into public.orders (client_id, kind, shorts_bought, size_source, amount, currency, payment_id, opened_at, period_end)
        select pay.client_id, s.kind, s.n, s.src, pay.amount, pay.currency, pay.id, pay.paid_at, pay.paid_at + interval '30 days'
        from public.order_size(pay.package, pay.amount) s;
      end if;
    exception when others then bad := bad + 1; last_err := format('payment %s: %s', pay.id, sqlerrm);
    end;
  end loop;
  update public.orders o set status = 'refunded', updated_at = now() from public.payments p
   where p.id = o.payment_id and p.refunded and o.status <> 'refunded';
  for f in select distinct client_id, order_name from public.deliveries where order_name is not null order by 1, 2 loop
    begin
      oid := public.order_for_folder(f.client_id, f.order_name);
      if oid is not null then perform public.order_rebuild(oid); n := n + 1; end if;
    exception when others then bad := bad + 1; last_err := format('folder %s: %s', f.order_name, sqlerrm);
    end;
  end loop;
  update public.orders set status = 'legacy', updated_at = now(), note = coalesce(note, 'backfill: old payment, no pack label, no order folder')
   where status = 'open' and folder is null and shorts_bought is null and opened_at < '2026-11-01';
  insert into public.sync_status (name, ran_at, ok, detail)
  values ('orders_rebuild', now(), bad = 0, left(format('%s folders rebuilt, %s skipped%s', n, bad, coalesce(' · last: ' || last_err, '')), 200))
  on conflict (name) do update set ran_at = excluded.ran_at, ok = excluded.ok, detail = excluded.detail;
  return n;
end $$;
revoke execute on function public.orders_rebuild_all(), public.order_rebuild(bigint), public.order_for_folder(uuid, text)
  from public, anon, authenticated;

-- 5) views again (same columns) + a revision_open problem; reads for founders only
create or replace view public.order_progress with (security_invoker = on) as
select o.id, o.client_id, c.name client, o.kind, o.status, o.shorts_bought bought, o.folder, o.opened_at, o.period_end,
       count(i.id)::int delivered,
       count(i.id) filter (where i.status = 'revision_requested')::int in_revision,
       count(i.id) filter (where i.status = 'revised')::int revised,
       count(i.posted_at)::int posted,
       greatest(o.shorts_bought - count(i.id), 0)::int left_to_deliver,
       max(i.last_version_at) last_delivery_at,
       case when o.shorts_bought is null or o.period_end is null then null
            else least(o.shorts_bought, ceil(o.shorts_bought * extract(epoch from (now() - o.opened_at))
                                              / nullif(extract(epoch from (o.period_end - o.opened_at)), 0)))::int end expected_by_now
from public.orders o
left join public.clients c on c.id = o.client_id
left join public.order_items i on i.order_id = o.id
group by o.id, c.name;

create or replace view public.order_problems with (security_invoker = on) as
select 'size_unknown' problem, o.id order_id, c.name client, coalesce(o.folder, o.payment_id) ref,
       format('$%s paid %s: pack size unknown, set it once', o.amount, to_char(o.opened_at, 'YYYY-MM-DD')) detail
from public.orders o left join public.clients c on c.id = o.client_id
where o.shorts_bought is null and o.status = 'open' and o.opened_at > now() - interval '60 days'
union all
select 'revision_open', i.order_id, c.name, i.title, format('Short %s: change asked %s, no newer version yet%s', i.slot,
       to_char(i.revision_asked_at at time zone 'Europe/Vilnius', 'MM-DD HH24:MI'), coalesce(' · ' || i.revision_note, ''))
from public.order_items i join public.orders o on o.id = i.order_id left join public.clients c on c.id = o.client_id
where i.status = 'revision_requested'
union all
select 'folder_unmatched', null, c.name, d.order_name, format('%s file(s) in a folder that matches no order', count(*))
from public.deliveries d left join public.clients c on c.id = d.client_id
where d.order_name is not null and d.order_name !~* '(internal|\mtests?\M|sample|earlier versions|replaced)'
  and not exists (select 1 from public.orders o where o.client_id = d.client_id and o.folder = d.order_name)
group by c.name, d.order_name
union all
select 'file_unnumbered', o.id, c.name, d.title, 'no usable "Short N" or no date: not counted'
from public.orders o join public.deliveries d on d.client_id = o.client_id and d.order_name = o.folder
left join public.clients c on c.id = o.client_id
where o.status <> 'legacy' and d.title !~* '(\msample\M|\(clean\))'
  and (d.delivered_at is null
       or coalesce(((regexp_match(d.title, '\m(?:short|reel)\s*(\d{1,4})\M', 'i'))[1])::int,
                   ((regexp_match(d.title, '^\s*(\d{1,2})\s+\D'))[1])::int, 0) not between 1 and 1000)
union all
select 'behind_pace', p.id, p.client, p.folder, format('%s of %s delivered, %s expected by now', p.delivered, p.bought, p.expected_by_now)
from public.order_progress p
where p.status = 'open' and p.delivered + 2 < p.expected_by_now
union all
select 'past_due', p.id, p.client, p.folder, format('%s of %s delivered; its 30 days ended %s', p.delivered, p.bought, to_char(p.period_end, 'YYYY-MM-DD'))
from public.order_progress p
where p.status = 'open' and p.kind <> 'monthly' and p.period_end < now() and p.left_to_deliver > 0
union all
select 'over_delivered', p.id, p.client, p.folder, format('%s delivered on a %s pack', p.delivered, p.bought)
from public.order_progress p where p.bought is not null and p.delivered > p.bought;

revoke all on public.order_progress, public.order_problems from anon, authenticated;
grant select on public.order_progress, public.order_problems to authenticated;   -- RLS on the base tables limits them to founders
