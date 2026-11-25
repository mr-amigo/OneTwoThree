-- Way B: the crawler's table reads the same files. failureReason exists as a column, and is NULL on
-- every event that does not carry it; int for amount is enough today (max below 2^31) but not by design.
SELECT count(*) AS events,
       count(failurereason) AS with_failure_reason,
       count(*) - count(failurereason) AS failure_reason_null,
       count_if(status = 'failure') AS failure_events,
       max(amount) AS max_amount_minor_units,
       2147483647 AS int_max,
       arbitrary(typeof(amount)) AS amount_type,
       arbitrary(typeof(createddate)) AS createddate_type
FROM crawled_payments
