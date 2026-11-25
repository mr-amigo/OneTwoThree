-- Way A, step 1: an external table over our copy of the raw JSON Lines, one partition per day.
-- Every field of the webhook, typed by hand. Dates stay strings here (ISO 8601 with a Z), and the
-- view converts them with from_iso8601_timestamp, so a malformed date cannot break the whole scan.
CREATE EXTERNAL TABLE IF NOT EXISTS payment_events (
  invoiceid     string  COMMENT 'the payment; all its events share it',
  status        string  COMMENT 'created, processing, success or failure',
  failurereason string  COMMENT 'only on failed payments',
  amount        bigint  COMMENT 'minor units (kopiyky, cents)',
  finalamount   bigint  COMMENT 'minor units; non-zero only on success',
  ccy           int     COMMENT 'ISO 4217: 980 UAH, 840 USD, 978 EUR',
  reference     string  COMMENT 'the order id on the merchant side',
  createddate   string  COMMENT 'when the payment was created (ISO 8601, UTC)',
  modifieddate  string  COMMENT 'when this status happened: event time',
  receivedat    string  COMMENT 'when the event reached us: processing time',
  merchantid    string,
  merchantname  string,
  mcc           int     COMMENT 'merchant category code',
  customerid    string,
  paymentmethod string,
  device        string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('case.insensitive' = 'true', 'ignore.malformed.json' = 'false')
LOCATION 's3://${BUCKET}/payments/'
TBLPROPERTIES ('classification' = 'json')
