-- crm_orders2.sql (Benas's side, 11-21): daily reconciliation for orders (needs crm_orders1.sql).
-- The triggers keep orders current within seconds; this nightly run re-derives everything from payments + deliveries,
-- so a missed trigger, a renamed folder or a late refund can never leave a wrong count for more than a day.
-- 03:15 UTC = 05:15 Vilnius (quiet hours). Rollback: select cron.unschedule('orders-rebuild-daily');
select cron.unschedule('orders-rebuild-daily') where exists (select 1 from cron.job where jobname = 'orders-rebuild-daily');
select cron.schedule('orders-rebuild-daily', '15 3 * * *', $$select public.orders_rebuild_all()$$);

-- crm-api keys: who may run the new actions (run by a founder, adjust the key names to the real ones)
--   reads + the two client facts for both Claudes:
--   update public.api_keys set actions = array(select distinct unnest(actions || array['orders','order_revision','order_posted']))
--    where name in ('benas-claude', 'simas-claude');
--   order_set (sizes, kind, status) stays on founder keys only.
