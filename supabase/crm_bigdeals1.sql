-- crm_bigdeals1.sql (Benas's side, 11-21): data for the main dashboard's "Big deals" card (BENAS 19:2x).
-- A big deal = an OPEN deal whose value is $300+/month, where value = the larger of the deal's own value (lead_stage /
-- opportunities) and the highest MONTHLY price we quoted to them in an email we sent ("$300 a month", "300 USD a month",
-- "15 Shorts a month for $300", "$840/mo"...). Read-only view, founders only (security_invoker). Additive.
create or replace view public.big_deals with (security_invoker = on) as
with q as (
  select lower(t.lead_email) e, t.at, replace(coalesce(m[1], m[2], m[3]), ',', '')::int usd
  from public.threads t,
       regexp_matches(t.body,
         '(?:\$|USD ?)\s?(\d{1,2},?\d{3}|\d{3})\s?(?:USD)?\s?(?:a month|/ ?mo\M|per month|monthly|/month)'
         || '|(?<![\d$])(\d{1,2},?\d{3}|\d{3}) ?USD (?:a month|per month|/ ?mo\M)'
         || '|\m\d{1,3} (?:Shorts|videos|Reels) (?:a|per) month (?:for|at) (?:\$|USD )?\s?(\d{1,2},?\d{3}|\d{3})', 'gi') m
  where t.direction = 'out' and t.body is not null
), quoted as (
  select e, max(usd) usd, max(at) last_quote_at from q group by e
)
select ls.email, ls.name, ls.owner, ls.stage, ls.days_in_stage, ls.overdue stale,
       greatest(coalesce(ls.deal_value_usd, 0), coalesce(ls.opp_value, 0), coalesce(qu.usd, 0))::int value_usd,
       qu.usd quoted_monthly_usd, qu.last_quote_at, ls.last_contact_at,
       coalesce(nx.next_step, ls.next_action) next_step, coalesce(nx.next_at, ls.next_action_at) next_at,
       ds.max_quiet_days
from public.lead_stage ls
left join quoted qu on qu.e = ls.email
left join public.lead_next_step nx on nx.email = ls.email
left join public.deal_stages ds on ds.stage = ls.stage
where ls.is_open
  and greatest(coalesce(ls.deal_value_usd, 0), coalesce(ls.opp_value, 0), coalesce(qu.usd, 0)) >= 300
order by ls.overdue desc, greatest(coalesce(ls.deal_value_usd, 0), coalesce(ls.opp_value, 0), coalesce(qu.usd, 0)) desc, ls.last_contact_at desc nulls last;
revoke all on public.big_deals from anon, authenticated;
grant select on public.big_deals to authenticated;
