-- Query 5 in UTC as well (the main query uses Kyiv local time), on Parquet.
SELECT hour(created_at) AS hour_utc,
       count(*) AS payments,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS share_pct
FROM payments_parquet
GROUP BY 1
ORDER BY 1
