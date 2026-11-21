-- crm_stage_lostflag1.sql (Simas's side, 11-21, BENAS's option (a) 19:58): a lost reason in lead_flags means LOST everywhere
-- (lead_stage → big_deals, pipeline_forecast, contacts). Won still beats lost. Patched from the LIVE definition; columns unchanged.
create or replace view public.lead_stage with (security_invoker = on) as
 WITH leads AS (
         SELECT lower(pipeline.email) AS e
           FROM pipeline
          WHERE pipeline.email IS NOT NULL
        UNION
         SELECT lower(interested_leads.email) AS lower
           FROM interested_leads
          WHERE interested_leads.email IS NOT NULL
        UNION
         SELECT lower(payments.email) AS lower
           FROM payments
          WHERE payments.email IS NOT NULL
        UNION
         SELECT lower(calls.email) AS lower
           FROM calls
          WHERE calls.email IS NOT NULL
        ), pay AS (
         SELECT lower(p.email) AS e,
            p.amount,
            p.paid_at,
            COALESCE(p.refunded, false) AS refunded
           FROM payments p
          WHERE p.email IS NOT NULL
        UNION ALL
         SELECT lower(ce.ce) AS lower,
            p.amount,
            p.paid_at,
            COALESCE(p.refunded, false) AS "coalesce"
           FROM payments p
             JOIN clients c ON c.id = p.client_id,
            LATERAL unnest(c.emails) ce(ce)
        ), paid AS (
         SELECT pay.e,
            sum(pay.amount) FILTER (WHERE NOT pay.refunded) AS amt,
            max(pay.paid_at) AS last_paid
           FROM pay
          GROUP BY pay.e
         HAVING sum(pay.amount) FILTER (WHERE NOT pay.refunded) > 0::numeric
        ), offer AS (
         SELECT lower(threads.lead_email) AS e,
            max(threads.at) AS at
           FROM threads
          WHERE threads.direction = 'out'::text AND threads.body ~* '(buy\.stripe\.com|bejucreative\.digital/(plans|scope)/)'::text
          GROUP BY (lower(threads.lead_email))
        ), inbound AS (
         SELECT lower(threads.lead_email) AS e,
            max(threads.at) AS at
           FROM threads
          WHERE threads.direction = 'in'::text
          GROUP BY (lower(threads.lead_email))
        ), booked AS (
         SELECT lower(calls.email) AS e,
            max(calls.start_at) AS at
           FROM calls
          WHERE COALESCE(calls.status, ''::text) <> 'cancelled'::text
          GROUP BY (lower(calls.email))
        ), opp AS (
         SELECT lower(opportunities.email) AS e,
            max(opportunities.value_usd) AS v
           FROM opportunities
          WHERE opportunities.email IS NOT NULL AND opportunities.closed_at IS NULL
          GROUP BY (lower(opportunities.email))
        ), lc AS (
         SELECT lead_timeline.email AS e,
            max(lead_timeline.at) AS at
           FROM lead_timeline
          WHERE (lead_timeline.kind = ANY (ARRAY['email'::text, 'call'::text, 'meeting'::text, 'dm'::text])) AND lead_timeline.status = 'done'::text AND lead_timeline.at <= now()
          GROUP BY lead_timeline.email
        ), s AS (
         SELECT l.e AS email,
            pl.name,
            pl.owner,
            pl.status,
            pl.fu_stage,
            pl.fu_day0,
            pl.next_action,
            pl.next_action_at,
                CASE
                    WHEN pd.e IS NOT NULL OR pl.status = 'WON'::text THEN 'won'::text
            WHEN lf.lost_reason IS NOT NULL THEN 'lost'::text
                    WHEN pl.status = 'LOST'::text OR pl.fu_stage = 'none'::text THEN 'lost'::text
                    WHEN pl.fu_stage = 'parked'::text THEN 'parked'::text
                    WHEN pl.fu_stage = 'said_yes'::text THEN 'committed'::text
                    WHEN pl.fu_stage = 'asked_price'::text OR o.e IS NOT NULL THEN 'proposal'::text
                    WHEN (pl.fu_stage = ANY (ARRAY['sample_sent'::text, 'thinking'::text])) OR (pl.status = ANY (ARRAY['DELIVERED'::text, 'HOT'::text])) OR b.e IS NOT NULL THEN 'engaged'::text
                    ELSE 'replied'::text
                END AS stage,
                CASE
                    WHEN pd.e IS NOT NULL THEN ((('paid $'::text || pd.amt::text) || ' (last '::text) || to_char((pd.last_paid AT TIME ZONE 'Europe/Vilnius'::text), 'YYYY-MM-DD'::text)) || ')'::text
                    WHEN pl.status = 'WON'::text THEN 'Samples status WON'::text
            WHEN lf.lost_reason IS NOT NULL THEN ('lost: '::text || lf.lost_reason) || COALESCE(': '::text || "left"(lf.lost_note, 120), ''::text)
                    WHEN pl.status = 'LOST'::text THEN 'Samples status LOST'::text
                    WHEN pl.fu_stage = 'none'::text THEN 'follow-ups stopped (fu_stage none), no payment'::text
                    WHEN pl.fu_stage = 'parked'::text THEN 'cadence finished'::text || COALESCE(': '::text || "left"(pl.fu_note, 120), ''::text)
                    WHEN pl.fu_stage = 'said_yes'::text THEN 'said yes, waiting for payment'::text || COALESCE(': '::text || "left"(pl.fu_note, 120), ''::text)
                    WHEN pl.fu_stage = 'asked_price'::text THEN 'price sent, quiet'::text || COALESCE(': '::text || "left"(pl.fu_note, 120), ''::text)
                    WHEN o.e IS NOT NULL THEN 'offer in writing on '::text || to_char((o.at AT TIME ZONE 'Europe/Vilnius'::text), 'YYYY-MM-DD'::text)
                    WHEN b.e IS NOT NULL THEN 'call booked for '::text || to_char((b.at AT TIME ZONE 'Europe/Vilnius'::text), 'YYYY-MM-DD'::text)
                    WHEN pl.fu_stage IS NOT NULL OR pl.status IS NOT NULL THEN ('sample / hot: status '::text || COALESCE(pl.status, ''::text)) || COALESCE(', fu '::text || pl.fu_stage, ''::text)
                    ELSE 'replied'::text || COALESCE(' on '::text || to_char((i.at AT TIME ZONE 'Europe/Vilnius'::text), 'YYYY-MM-DD'::text), ''::text)
                END AS evidence,
            LEAST(
                CASE
                    WHEN pd.e IS NOT NULL THEN pd.last_paid
            WHEN lf.lost_reason IS NOT NULL THEN COALESCE(lf.lost_at, lf.updated_at)
                    WHEN pl.fu_stage = 'parked'::text THEN LEAST(pl.stage_changed_at, pl.fu_day0)
                    WHEN pl.fu_stage = ANY (ARRAY['said_yes'::text, 'asked_price'::text, 'sample_sent'::text, 'thinking'::text]) THEN pl.fu_day0
                    WHEN o.e IS NOT NULL THEN o.at
                    WHEN b.e IS NOT NULL THEN b.at
                    ELSE COALESCE(i.at, pl.last_reply_at, pl.updated_at)
                END, now()) AS stage_since,
            op.v AS opp_value
           FROM leads l
             LEFT JOIN pipeline pl ON lower(pl.email) = l.e
             LEFT JOIN paid pd ON pd.e = l.e
             LEFT JOIN offer o ON o.e = l.e
             LEFT JOIN inbound i ON i.e = l.e
             LEFT JOIN booked b ON b.e = l.e
             LEFT JOIN opp op ON op.e = l.e
             LEFT JOIN lead_flags lf ON lf.email = l.e
        )
 SELECT s.email,
    s.name,
    s.owner,
    s.status,
    s.fu_stage,
    s.fu_day0,
    s.next_action,
    s.next_action_at,
    s.stage,
    s.evidence,
    s.stage_since,
    s.opp_value,
    ds.ord,
    ds.is_open,
    ds.probability,
    COALESCE(s.opp_value, ds.default_value_usd) AS deal_value_usd,
    floor(EXTRACT(epoch FROM now() - s.stage_since) / 86400::numeric)::integer AS days_in_stage,
    ds.is_open AND ds.max_quiet_days IS NOT NULL AND s.stage_since < (now() - make_interval(days => ds.max_quiet_days)) AS overdue,
    lc.at AS last_contact_at
   FROM s
     JOIN deal_stages ds ON ds.stage = s.stage
     LEFT JOIN lc ON lc.e = s.email;
