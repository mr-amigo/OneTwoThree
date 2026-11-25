-- Part 3: what came through Kinesis and Firehose (stream_payments: Parquet, partitioned by event day).
SELECT dt,
       count(*) AS events,
       count(DISTINCT invoiceid) AS payments,
       count_if(drill) AS drill_events,
       min(producedat) AS first_sent,
       max(producedat) AS last_sent,
       count(DISTINCT "$path") AS parquet_files
FROM stream_payments
WHERE dt = '2026-10-01'
GROUP BY dt
