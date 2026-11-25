-- Did every event of the day arrive? The stream partition against the batch partition of the same day.
WITH stream AS (
  SELECT count(*) AS events, count(DISTINCT invoiceid) AS payments,
         count(DISTINCT concat_ws('|', invoiceid, status, modifieddate)) AS distinct_events
  FROM stream_payments WHERE dt = '2026-10-01'
),
batch AS (
  SELECT count(*) AS events, count(DISTINCT invoiceid) AS payments,
         count(DISTINCT concat_ws('|', invoiceid, status, modifieddate)) AS distinct_events
  FROM payment_events WHERE dt = '2026-10-01'
)
SELECT 'stream' AS source, * FROM stream
UNION ALL
SELECT 'batch', * FROM batch
