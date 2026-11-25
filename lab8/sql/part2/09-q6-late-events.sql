-- Query 6: events that arrived more than 60 seconds after they happened (receivedAt - modifiedDate),
-- out of all events (exact duplicates removed, so a re-delivery is not counted twice).
WITH events AS (
  SELECT DISTINCT * FROM payment_events
),
lag AS (
  SELECT status, date_diff('second', from_iso8601_timestamp(modifieddate), from_iso8601_timestamp(receivedat)) AS delay_s
  FROM events
)
SELECT count(*) AS events,
       count_if(delay_s > 60) AS late_over_60s,
       round(100.0 * count_if(delay_s > 60) / count(*), 2) AS late_pct,
       count_if(delay_s > 600) AS late_over_10min,
       count_if(delay_s > 3600) AS late_over_1h,
       max(delay_s) AS max_delay_s,
       approx_percentile(delay_s, 0.5) AS median_delay_s,
       approx_percentile(delay_s, 0.99) AS p99_delay_s
FROM lag
