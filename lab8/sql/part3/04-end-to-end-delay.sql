-- How long from the producer to a queryable file in S3? producedAt vs the Parquet file's write time
-- ("$file_modified_time"): mostly Firehose's 60-second buffer.
SELECT "$path" AS file,
       count(*) AS events,
       min(from_iso8601_timestamp(producedat)) AS first_sent,
       max(from_iso8601_timestamp(producedat)) AS last_sent,
       "$file_modified_time" AS written,
       date_diff('second', max(from_iso8601_timestamp(producedat)), "$file_modified_time") AS last_event_to_file_s
FROM stream_payments
WHERE dt = '2026-10-01'
GROUP BY 1, 5
ORDER BY 3
