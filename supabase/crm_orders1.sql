-- crm_orders1.sql (Benas's side, 11-21): orders + per-Short delivery status. ADDITIVE ONLY: no existing table, function,
-- trigger or webhook is changed. Rollback: drop the two triggers, the four functions, the two views and the two tables.
--
-- BENAS 11-21 rules:
--  * One order per purchase or renewal. Pack size comes from the Stripe package label, else an exact price, else it stays
--    NULL and shows in order_problems for a founder to set once. Never guessed.
--  * A Short is DELIVERED when its file is in the client's order folder (client folders hold approved finals only).
--    INTERNAL / test / sample / "Earlier versions" folders never count. The clean free sample in a pack folder never counts.
--  * Per Short: delivered -> revision_requested (the client asked for a change) -> revised (a newer version arrived).
--    v2/v3 of the same Short number stays ONE Short. Nothing is inferred from silence; there is no "approved" state.
--
-- How it fills itself:
--  * payments INSERT (stripe-webhook, finance sync) -> trigger opens the order (monthly renewals too).
--  * deliveries INSERT/UPDATE (Drive sync) -> trigger attaches the file's folder to an order and rebuilds that order's
--    items. Folder -> order: "Order N" / "Month N" = the client's N-th paid order; "Referral" = a free referral order;
--    old folders with no "·" = legacy history. Anything unclear goes to order_problems, never a guess.
--  * orders_rebuild_all() re-derives everything (backfill + daily reconciliation).

-- ---------------------------------------------------------------- tables
create table if not exists public.orders (
  id            bigint generated always as identity primary key,
  client_id     uuid references public.clients on delete set null,
  kind          text not null check (kind in ('pack', 'monthly', 'long', 'custom', 'referral', 'legacy')),
  shorts_bought int check (shorts_bought is null or shorts_bought between 0 and 1000),   -- NULL = unknown: a founder sets it
  size_source   text check (size_source in ('label', 'price', 'folder', 'founder')),
  amount        numeric,
  currency      text default 'usd',
  payment_id    text unique,                       -- Stripe charge id (payments.id); NULL for referral / legacy
  opened_at     timestamptz not null,
  period_end    timestamptz,                       -- opened_at + 30 days (packs are used within 30 days, monthly = 1 month)
  folder        text,                              -- the Drive order folder name, once matched
  status        text not null default 'open' check (status in ('open', 'complete', 'paused', 'refunded', 'legacy', 'canceled')),
  note          text,
  created_by    text not null default 'system',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (client_id, folder)
);
create index if not exists orders_client on public.orders (client_id, opened_at);

create table if not exists public.order_items (
  id               bigint generated always as identity primary key,
  order_id         bigint not null references public.orders on delete cascade,
  slot             int not null check (slot between 1 and 1000),   -- the Short's number in the file name
  title            text,
  delivered_at     timestamptz not null,                            -- first version reached the client folder
  last_version     int not null default 1,
  last_version_at  timestamptz not null,
  file_ids         text[] not null default '{}',                   -- deliveries.id of every version
  revision_asked_at timestamptz,                                    -- set by a founder / Claude when the client asks
  revision_note    text,
  posted_at        timestamptz,                                     -- seen on their channel
  status           text generated always as (
                     case when revision_asked_at is null then (case when last_version > 1 then 'revised' else 'delivered' end)
                          when last_version_at > revision_asked_at then 'revised'
                          else 'revision_requested' end) stored,
  updated_at       timestamptz not null default now(),
  unique (order_id, slot)
);

alter table public.orders enable row level security;
alter table public.order_items enable row level security;
drop policy if exists "founders read" on public.orders;
create policy "founders read" on public.orders for select using (public.is_admin());
drop policy if exists "founders read" on public.order_items;
create policy "founders read" on public.order_items for select using (public.is_admin());
revoke all on public.orders, public.order_items from anon, authenticated;
grant select on public.orders, public.order_items to authenticated;   -- reads only; RLS limits them to founders
-- writes: the triggers/functions below (security definer) and the service role. No client key writes here.

-- ---------------------------------------------------------------- pack size: label, then exact price, else NULL
create or replace function public.order_size(pkg text, amt numeric, out n int, out src text, out kind text)
language plpgsql immutable as $$
declare m text[];
begin
  pkg := lower(coalesce(pkg, ''));
  kind := case when pkg ~ '(monthly|_month)' then 'monthly' when pkg ~ '^long' then 'long' else 'pack' end;
  if pkg = 'monthly_growth_300' then n := 15; src := 'label'; return; end if;
  if pkg = 'monthly_daily_500'  then n := 30; src := 'label'; return; end if;
  m := regexp_match(pkg, '(?:short|long)_(\d+)|monthly_(\d+)_|_(\d+)_month');
  if m is not null then n := coalesce(m[1], m[2], m[3])::int; src := 'label'; return; end if;
  -- exact prices with one meaning only ($300 a month is 15 OR 30, so it is NOT here)
  n := case round(coalesce(amt, 0)) when 75 then 5 when 60 then 3 when 150 then 5 when 500 then 30 else null end;
  src := case when n is null then null else 'price' end;
  if round(coalesce(amt, 0)) = 500 then kind := 'monthly'; end if;
end $$;

-- ---------------------------------------------------------------- payment -> order
create or replace function public.orders_from_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if new.refunded then return new; end if;
  select * into s from public.order_size(new.package, new.amount);
  insert into public.orders (client_id, kind, shorts_bought, size_source, amount, currency, payment_id, opened_at, period_end)
  values (new.client_id, s.kind, s.n, s.src, new.amount, new.currency, new.id, new.paid_at, new.paid_at + interval '30 days')
  on conflict (payment_id) do nothing;
  return new;
end $$;
drop trigger if exists orders_from_payment on public.payments;
create trigger orders_from_payment after insert on public.payments for each row execute function public.orders_from_payment();

-- ---------------------------------------------------------------- folder -> order, then items
create or replace function public.order_for_folder(p_client uuid, p_folder text) returns bigint
language plpgsql security definer set search_path = public as $$
declare oid bigint; k int; fsize int; d timestamptz; m text[];
begin
  if p_client is null or p_folder is null then return null; end if;
  if p_folder ~* '(internal|\mtest|sample|earlier versions|replaced)' then return null; end if;   -- never counts
  select id into oid from public.orders where client_id = p_client and folder = p_folder;
  if oid is not null then return oid; end if;
  fsize := (regexp_match(p_folder, '^\s*(\d+)[\s-]*(?:shorts?|short form|videos?|long form)', 'i'))[1]::int;
  d := coalesce((((regexp_match(p_folder, '(\d{4}-\d{2}-\d{2})'))[1]) || ' 12:00 Europe/Vilnius')::timestamptz, now());
  if p_folder ~* '·\s*referral\s*·' then                             -- free referral Shorts: no payment
    insert into public.orders (client_id, kind, shorts_bought, size_source, opened_at, period_end, folder, created_by)
    values (p_client, 'referral', fsize, 'folder', d, d + interval '30 days', p_folder, 'orders_sync') returning id into oid;
    return oid;
  end if;
  m := regexp_match(p_folder, '·\s*(?:order|month)\s+(\d+)\s*·', 'i');
  if m is null then                                                   -- old naming: history, counted by files
    insert into public.orders (client_id, kind, shorts_bought, size_source, opened_at, folder, status, created_by)
    values (p_client, 'legacy', fsize, 'folder', d, p_folder, 'legacy', 'orders_sync') returning id into oid;
    return oid;
  end if;
  k := m[1]::int;
  -- 1) the unmatched paid order whose payment day (Vilnius) is closest to the folder's date, within 3 days
  if p_folder ~ '\d{4}-\d{2}-\d{2}' then
    select id into oid from public.orders
     where client_id = p_client and folder is null and kind in ('pack', 'monthly', 'long', 'custom')
       and abs((opened_at at time zone 'Europe/Vilnius')::date - d::date) <= 3
     order by abs((opened_at at time zone 'Europe/Vilnius')::date - d::date), opened_at limit 1;
  end if;
  -- 2) else the client's k-th paid order ("Order k" / "Month k"), if not yet matched
  if oid is null then
  select id into oid from (
    select id, folder, row_number() over (order by opened_at, id) rn
    from public.orders where client_id = p_client and kind in ('pack', 'monthly', 'long', 'custom')) o
  where rn = k and folder is null;
  end if;
  if oid is null then return null; end if;                            -- unclear: order_problems shows the folder
  update public.orders set folder = p_folder, updated_at = now(),
         shorts_bought = coalesce(shorts_bought, fsize), size_source = coalesce(size_source, case when fsize is null then null else 'folder' end)
   where id = oid;
  return oid;
end $$;

create or replace function public.order_rebuild(p_order bigint) returns void
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.orders where id = p_order;
  if o.folder is null then return; end if;
  with f as (
    select d.id, d.title, d.delivered_at::timestamptz at, m.slot, coalesce(v.ver, 1) ver
    from public.deliveries d
    cross join lateral (select coalesce((regexp_match(d.title, '\m(?:short|reel)\s*(\d+)\M', 'i'))[1],
                                        (regexp_match(d.title, '^\s*(\d{1,2})\s+\D'))[1])::int slot) m
    left join lateral (select coalesce(x[1], x[2])::int ver from regexp_match(d.title, '\mv(\d+)\M|\(v(\d+)\)', 'i') x) v on true
    where d.client_id = o.client_id and d.order_name = o.folder and d.title !~* '(\msample\M|\(clean\))' and m.slot is not null
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
  -- a slot whose files all left the folder (e.g. moved to "Earlier versions") disappears, unless someone logged a revision on it
  delete from public.order_items i where i.order_id = p_order and i.revision_asked_at is null and i.posted_at is null
     and not exists (select 1 from public.deliveries d where d.id = any(i.file_ids) and d.order_name = o.folder);
  update public.orders set status = 'complete', updated_at = now()
   where id = p_order and status = 'open' and shorts_bought is not null
     and (select count(*) from public.order_items where order_id = p_order) >= shorts_bought;
end $$;

create or replace function public.orders_from_delivery() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid bigint;
begin
  oid := public.order_for_folder(new.client_id, new.order_name);
  if oid is not null then perform public.order_rebuild(oid); end if;
  if tg_op = 'UPDATE' and old.order_name is distinct from new.order_name then   -- moved out of a folder: rebuild the old one too
    select id into oid from public.orders where client_id = old.client_id and folder = old.order_name;
    if oid is not null then perform public.order_rebuild(oid); end if;
  end if;
  return new;
end $$;
drop trigger if exists orders_from_delivery on public.deliveries;
create trigger orders_from_delivery after insert or update of order_name, title, client_id on public.deliveries
  for each row execute function public.orders_from_delivery();

-- backfill + daily reconciliation: idempotent, safe to run any time
create or replace function public.orders_rebuild_all() returns int
language plpgsql security definer set search_path = public as $$
declare pay record; f record; n int := 0; oid bigint;
begin
  for pay in select * from public.payments where not refunded order by paid_at loop
    perform 1 from public.orders where payment_id = pay.id;
    if not found then
      insert into public.orders (client_id, kind, shorts_bought, size_source, amount, currency, payment_id, opened_at, period_end)
      select pay.client_id, s.kind, s.n, s.src, pay.amount, pay.currency, pay.id, pay.paid_at, pay.paid_at + interval '30 days'
      from public.order_size(pay.package, pay.amount) s;
    end if;
  end loop;
  update public.orders o set status = 'refunded', updated_at = now() from public.payments p
   where p.id = o.payment_id and p.refunded and o.status <> 'refunded';
  for f in select distinct client_id, order_name from public.deliveries where order_name is not null order by 1, 2 loop
    oid := public.order_for_folder(f.client_id, f.order_name);
    if oid is not null then perform public.order_rebuild(oid); n := n + 1; end if;
  end loop;
  -- before the "N Shorts · Order k · date" folders (11-01), unlabeled payments with no folder were IG-era / custom deals:
  -- keep them as history so they never show as open work
  update public.orders set status = 'legacy', updated_at = now(), note = coalesce(note, 'backfill: old payment, no pack label, no order folder')
   where status = 'open' and folder is null and shorts_bought is null and opened_at < '2026-11-01';
  return n;
end $$;
revoke execute on function public.orders_rebuild_all(), public.order_rebuild(bigint), public.order_for_folder(uuid, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- what the CRM shows
create or replace view public.order_progress with (security_invoker = on) as
select o.id, o.client_id, c.name client, o.kind, o.status, o.shorts_bought bought, o.folder, o.opened_at, o.period_end,
       count(i.id)::int delivered,
       count(i.id) filter (where i.status = 'revision_requested')::int in_revision,
       count(i.id) filter (where i.status = 'revised')::int revised,
       count(i.posted_at)::int posted,
       greatest(o.shorts_bought - count(i.id), 0)::int left_to_deliver,
       max(i.last_version_at) last_delivery_at,
       -- pace: how many should be out by now if spread evenly over the period
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
select 'folder_unmatched', null, c.name, d.order_name, format('%s file(s) in a folder that matches no order', count(*))
from public.deliveries d left join public.clients c on c.id = d.client_id
where d.order_name is not null and d.order_name !~* '(internal|\mtest|sample|earlier versions|replaced)'
  and not exists (select 1 from public.orders o where o.client_id = d.client_id and o.folder = d.order_name)
group by c.name, d.order_name
union all
select 'file_unnumbered', o.id, c.name, d.title, 'no "Short N" in the file name: not counted'
from public.orders o join public.deliveries d on d.client_id = o.client_id and d.order_name = o.folder
left join public.clients c on c.id = o.client_id
where o.status <> 'legacy' and d.title !~* '(\msample\M|\(clean\))'
  and coalesce((regexp_match(d.title, '\m(?:short|reel)\s*(\d+)\M', 'i'))[1], (regexp_match(d.title, '^\s*(\d{1,2})\s+\D'))[1]) is null
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
