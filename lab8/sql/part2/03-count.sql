-- Way A, step 3: the table sees all events (about three million) in 31 partitions.
SELECT count(*) AS events, count(DISTINCT dt) AS partitions, min(dt) AS first_day, max(dt) AS last_day
FROM payment_events
