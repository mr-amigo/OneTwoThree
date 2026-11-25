-- Fair comparison, query 4 on deduplicated JSON: share of failed payments per payment method and device, highest first.
-- Only payments that finished (success or failure) count; a payment still in created/processing has no outcome yet.
SELECT paymentmethod, device,
       count(*) AS finished_payments,
       count_if(status = 'failure') AS failed,
       round(100.0 * count_if(status = 'failure') / count(*), 2) AS failure_pct
FROM payments_json
WHERE status IN ('success', 'failure')
GROUP BY 1, 2
ORDER BY failure_pct DESC, paymentmethod, device
