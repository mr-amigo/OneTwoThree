Crawler table `crawled_payments`: classification `json`, SerDe `org.openx.data.jsonserde.JsonSerDe`, partition keys [('dt', 'string')], 31 partitions registered, records sampled: 1202922, last crawl SUCCEEDED.

| column | hand-written (payment_events) | crawler (crawled_payments) |
|---|---|---|
| invoiceid | string | string |
| status | string | string |
| failurereason | string | string |
| amount | bigint | int |
| finalamount | bigint | int |
| ccy | int | int |
| reference | string | string |
| createddate | string | string |
| modifieddate | string | string |
| receivedat | string | string |
| merchantid | string | string |
| merchantname | string | string |
| mcc | int | int |
| customerid | string | string |
| paymentmethod | string | string |
| device | string | string |
| dt (partition) | string | string |
