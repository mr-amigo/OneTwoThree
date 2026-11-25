-- The alert, checked in SQL: share of failed payments per merchant in the stream, with the incident
-- drill separated out. Latest status per payment, duplicates removed, as in Part 2.
WITH latest AS (
  SELECT *, row_number() OVER (PARTITION BY invoiceid
                               ORDER BY modifieddate DESC,
                                        CASE status WHEN 'success' THEN 3 WHEN 'failure' THEN 3 WHEN 'processing' THEN 2 ELSE 1 END DESC) AS rn
  FROM stream_payments WHERE dt = '2026-10-01'
)
SELECT merchantid, merchantname,
       count(*) AS finished_payments,
       count_if(status = 'failure') AS failed,
       count_if(drill) AS failed_in_drill,
       round(100.0 * count_if(status = 'failure') / count(*), 2) AS failure_pct,
       round(100.0 * count_if(status = 'failure' AND NOT drill) / count_if(NOT drill), 2) AS failure_pct_without_drill
FROM latest
WHERE rn = 1 AND status IN ('success', 'failure')
GROUP BY 1, 2
ORDER BY failure_pct DESC
