-- 11-25: finance-sync edge function (Stripe API -> finance_snapshot id='stripe'), every 15 minutes, no Mac needed.
-- Deploy: Beju Dashboard/scripts/data/work/crm_backend_1121/deploy.py finance-sync false   (needs secrets CRON_SECRET + STRIPE_SECRET_KEY)
-- The x-cron-secret header is copied server-side from the ops-sync job, so the secret never appears in this file.
select cron.schedule('finance-sync', '3-59/15 * * * *',
  replace(replace((select command from cron.job where jobname = 'ops-sync'), '/functions/v1/ops-sync', '/functions/v1/finance-sync'),
          'timeout_milliseconds := 120000', 'timeout_milliseconds := 90000'));
-- Check:   select status_code, left(content::text, 300) from net._http_response order by id desc limit 5;
-- Remove:  select cron.unschedule('finance-sync');
