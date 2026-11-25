-- The answers about scale: unique payments, duplicates, and how late events arrive.
WITH raw AS (
  SELECT count(*) AS events FROM payment_events
),
events AS (
  SELECT DISTINCT * FROM payment_events
),
d AS (
  SELECT count(*) AS distinct_events,
         count(DISTINCT invoiceid) AS unique_invoices,
         count_if(date_diff('second', from_iso8601_timestamp(modifieddate), from_iso8601_timestamp(receivedat)) > 3600) AS late_over_1h
  FROM events
)
SELECT raw.events AS events_with_duplicates,
       d.distinct_events,
       raw.events - d.distinct_events AS exact_duplicates,
       round(100.0 * (raw.events - d.distinct_events) / raw.events, 2) AS duplicates_pct,
       d.unique_invoices,
       round(1.0 * d.distinct_events / d.unique_invoices, 2) AS events_per_payment,
       d.late_over_1h,
       round(100.0 * d.late_over_1h / d.distinct_events, 4) AS late_over_1h_pct
FROM raw CROSS JOIN d
