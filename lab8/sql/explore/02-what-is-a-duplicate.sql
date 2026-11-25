-- What does a duplicate look like? Groups of one invoice, one status, one event time.
WITH g AS (
  SELECT invoiceid, status, modifieddate,
         count(*) AS copies,
         count(DISTINCT receivedat) AS received_times,
         count(DISTINCT dt) AS partitions,
         count(DISTINCT concat_ws('|', coalesce(failurereason, ''), CAST(amount AS varchar), CAST(finalamount AS varchar),
           CAST(ccy AS varchar), reference, createddate, merchantid, merchantname, CAST(mcc AS varchar), customerid,
           paymentmethod, device)) AS payloads
  FROM payment_events
  GROUP BY 1, 2, 3
  HAVING count(*) > 1
)
SELECT count(*) AS duplicated_events, sum(copies - 1) AS extra_copies, max(copies) AS max_copies,
       count_if(received_times > 1) AS with_different_receivedat,
       count_if(partitions > 1) AS in_two_partitions,
       count_if(payloads > 1) AS with_different_payload
FROM g
