-- Query 5 on Parquet: payments per hour of the day, by the hour the payment was created, in Kyiv local time
-- (Parquet stores UTC without a zone, hence with_timezone; at_timezone also handles the switch from summer time on 25 October).
SELECT hour(at_timezone(with_timezone(created_at, 'UTC'), 'Europe/Kyiv')) AS hour_kyiv,
       count(*) AS payments,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS share_pct
FROM payments_parquet
GROUP BY 1
ORDER BY 1
