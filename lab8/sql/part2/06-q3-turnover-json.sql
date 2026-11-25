-- Query 3: turnover by merchant and currency, successful payments only, in major units (hryvnias, dollars, euros).
SELECT merchantid, merchantname,
       CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR' ELSE CAST(ccy AS varchar) END AS currency,
       count(*) AS payments,
       CAST(sum(finalamount) AS decimal(22, 2)) / 100 AS turnover,  -- exact: integers in minor units, then /100
       CAST(avg(finalamount) / 100 AS decimal(12, 2)) AS average_payment
FROM payments
WHERE status = 'success'
GROUP BY 1, 2, 3
ORDER BY currency, turnover DESC
