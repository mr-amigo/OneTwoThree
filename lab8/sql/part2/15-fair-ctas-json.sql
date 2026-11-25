-- Fair comparison, step 1: the same deduplicated payments as query 7, written as JSON instead of Parquet.
-- Then queries 3-5 do exactly the same work on both tables, and only the file format differs.
-- clean: curated-json/payments/
CREATE TABLE payments_json
WITH (
  format = 'JSON',
  write_compression = 'NONE',
  external_location = 's3://${BUCKET}/curated-json/payments/',
  partitioned_by = ARRAY['dt']
) AS
SELECT invoiceid, status, failurereason, amount, finalamount, ccy, reference,
       created_at, modified_at, received_at,
       merchantid, merchantname, mcc, customerid, paymentmethod, device,
       dt
FROM payments
