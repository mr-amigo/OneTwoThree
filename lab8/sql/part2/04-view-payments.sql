-- Query 2: deduplication. One row per invoiceId: the event with the latest modifiedDate.
--   1. DISTINCT removes exact duplicates (about 1% of events are delivered twice, byte for byte).
--   2. row_number() keeps the latest status of each payment. Ties on modifiedDate are broken by the
--      status order (a final status wins over processing over created), then by receivedAt.
-- Dates become real timestamps (UTC) here, so every query below can use date functions directly.
CREATE OR REPLACE VIEW payments AS
WITH events AS (
  SELECT DISTINCT * FROM payment_events
),
ranked AS (
  SELECT *,
         row_number() OVER (
           PARTITION BY invoiceid
           ORDER BY from_iso8601_timestamp(modifieddate) DESC,
                    CASE status WHEN 'success' THEN 3 WHEN 'failure' THEN 3 WHEN 'processing' THEN 2 ELSE 1 END DESC,
                    receivedat DESC
         ) AS rn
  FROM events
)
SELECT invoiceid, status, failurereason, amount, finalamount, ccy, reference,
       -- UTC as plain timestamps: a view (like Parquet) cannot hold "timestamp with time zone".
       CAST(from_iso8601_timestamp(createddate) AS timestamp(3))  AS created_at,
       CAST(from_iso8601_timestamp(modifieddate) AS timestamp(3)) AS modified_at,
       CAST(from_iso8601_timestamp(receivedat) AS timestamp(3))   AS received_at,
       merchantid, merchantname, mcc, customerid, paymentmethod, device, dt
FROM ranked
WHERE rn = 1
