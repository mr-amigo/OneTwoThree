-- Query 7: the deduplicated payments as Parquet (Snappy), partitioned by dt, under curated/.
-- clean: curated/payments/
-- (the line above makes scripts/athena.py empty the prefix first: CTAS refuses a non-empty location)
CREATE TABLE payments_parquet
WITH (
  format = 'PARQUET',
  write_compression = 'SNAPPY',
  external_location = 's3://${BUCKET}/curated/payments/',
  partitioned_by = ARRAY['dt']
) AS
SELECT invoiceid, status, failurereason, amount, finalamount, ccy, reference,
       created_at, modified_at, received_at,  -- UTC timestamps (Parquet INT96/INT64), not strings
       merchantid, merchantname, mcc, customerid, paymentmethod, device,
       dt
FROM payments
