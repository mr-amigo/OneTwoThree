-- Query 5: payments per hour of the day, by the hour the payment was created, in Kyiv local time
-- (the timestamps are UTC, hence with_timezone; at_timezone also handles the switch from summer time on 25 October).
SELECT hour(at_timezone(with_timezone(created_at, 'UTC'), 'Europe/Kyiv')) AS hour_kyiv,
       count(*) AS payments,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS share_pct
FROM payments
GROUP BY 1
ORDER BY 1
