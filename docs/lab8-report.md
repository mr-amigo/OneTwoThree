# Lab 8: Big Data on AWS. Report

The cloud route is used throughout: Part 2 is done on AWS (Athena, Glue), and Part 3 is a working
Kinesis → Firehose → S3 → Athena pipeline with an SNS alert.

- Everything was created with Terraform (`lab8/infra`) and run with `lab8/Makefile`.
- The SQL is in `lab8/sql/`, and the raw results, statistics and screenshots are in
  [`lab8-runs/`](lab8-runs/).
- Region us-east-1, account of the course project, 24–25 November 2026.

| What | Where |
| --- | --- |
| Part 1 answers | [below](#part-1-ukloncs-data-architecture) |
| Part 2 queries | `lab8/sql/part2/01…14-*.sql` |
| Part 2 results | `lab8-runs/part2/*.csv`, `stats.md` (data scanned, run time), `crawler-schema.md`, screenshot `athena-console-recent-queries.png` |
| Part 3 diagram | `lab8-runs/part3/pipeline-diagram.png` (source `lab8/diagram/pipeline.html`) |
| Part 3 producer | `lab8/producer/producer.py` (alert consumer: `lab8/alerter/handler.py`) |
| Part 3 Athena over the stream | `lab8-runs/part3/athena-console-stream-query.png`, `lab8/sql/part3/*.sql`, `lab8-runs/part3/*.csv` |
| Part 3 cost | [below](#what-it-cost) |

## Part 1: Uklon's data architecture

**What happens if the real-time road falls behind by 10 minutes? And the batch road by a day?**

If the real-time road is 10 minutes behind, the product breaks while it is still running:
- Matching works with driver positions that are 10 minutes old (a car can be 5–10 km away by then).
- Surge pricing reacts to demand that has already changed: too low in a rush, too high after it.
- The ETA and the car on the passenger's map are wrong.
- Fraud and safety alerts come after the ride is over.

Passengers cancel, drivers drive to the wrong places, and money is lost every minute of the lag.

The data is not lost: Kinesis keeps it (24 h by default, up to 365 days), so Flink catches up by
reading faster. But catching up means processing stale events, which is useless for real-time
decisions. Real-time pipelines therefore watch the consumer lag (`IteratorAgeMilliseconds`) and
drop stale events rather than act on them.

If the batch road is a day behind, nothing in the ride breaks. The dashboards and reports are one
day older, finance closes the day later, and ML training uses yesterday's data. It is an
inconvenience, not an outage. The nightly job is re-run, and the raw data in S3 is still there.

**Why does GPS not go through Lambda?**
- **Volume and cost.** 580 M pings a day is about 6,700 per second on average and several times
  that at the peak. One invocation per ping is about 17 billion invocations a month. Requests and
  duration alone cost thousands of dollars, and through API Gateway it would be tens of thousands.
  A persistent MQTT connection to IoT Core and then a stream cost a fraction of that.
- **Connection model.** A phone sending every 3 seconds wants one long-lived, cheap connection
  (MQTT keep-alive works on bad mobile networks), not a new HTTPS request with TLS every time.
- **What the work needs.** Position tracking is stateful and ordered: the last position per driver,
  speed between pings, geofences. Lambda is stateless and scales by running more copies with no order
  across them. A stream partitioned by driver gives ordered, replayable input to Flink, which keeps
  state per key.
- **Limits.** Concurrency quotas and cold starts would add latency and throttling exactly at the peak.

**Which parts would a small startup drop first, and what would it lose?**

| Drop | What it loses |
| --- | --- |
| Flink | Continuous stream processing with state (surge per district each second). Replace with a periodic job or a Lambda on the stream: surge recalculated every minute instead of continuously. |
| SageMaker | Trained ETA and demand models. Use a heuristic (distance ÷ average speed by hour). Lower accuracy, no personalisation. |
| DMS change data capture | The database changes in the lake in near real time. Use a nightly export from Aurora: the lake is a day old. |
| IoT Core | Cheap, scalable GPS at large scale. At a startup's volume an HTTPS endpoint or WebSocket into the same stream is fine, until it is not. |
| Glue jobs, the Data Catalog's crawlers, Amazon Quick | The curated Parquet layer, automatic schemas, self-service dashboards. Query raw JSON with Athena and accept the higher bill per query, or run SQL on a read replica. |
| Redis / DynamoDB split | Two specialised stores. Keep driver positions in Redis only (or PostgreSQL + PostGIS): simpler, with less headroom. |

What a startup keeps: the apps, one database, a stream (or even just a queue), S3 as the lake and
Athena. Those are cheap when idle, and every later addition plugs into them.

## Part 2: Batch on AWS

**Way A (`lab8/sql/part2`).**
- *Table.* `payment_events` is an external table with the OpenX JSON SerDe, every field typed by hand
  (amounts `bigint` in minor units, `ccy` and `mcc` `int`, dates as ISO-8601 strings converted in the
  view), and `dt` as the partition key. `MSCK REPAIR TABLE` registered 31 partitions.
  `COUNT(*)` = **3,030,197** events.
- *What `dt` is.* `dt` is the event day: `substr(modifiedDate,1,10) = dt` for 100% of rows
  (`lab8-runs/explore/01-what-is-dt.csv`).
- *What a duplicate is.* Duplicates are byte-for-byte copies, even `receivedAt` is the same: 30,197
  of them, at most 2 copies, never in two partitions (`explore/02`). So `SELECT DISTINCT *` removes
  every one of them.

### Answers about scale (`05-scale.csv`, `09-q6-late-events.csv`)

| | |
| --- | --- |
| Events with duplicates | 3,030,197 |
| Exact duplicates | **30,197** (1.00%) |
| Distinct events | 3,000,000 |
| Unique `invoiceId` (payments) | **1,000,000** (3.0 events per payment: created → processing → success/failure) |
| Events more than 60 s late (query 6) | **60,231 of 3,000,000 = 2.01%** |
| Events more than 10 min / 1 hour late | 0 / **0 (0.00%)**: the maximum delay is exactly 600 s; median 1 s, p99 325 s |

### Results of queries 2–6
- **Query 2, deduplication:** view `payments`.
  1. `SELECT DISTINCT *` removes the exact duplicates.
  2. `row_number() OVER (PARTITION BY invoiceid ORDER BY modifiedDate DESC, <final status first>, receivedAt DESC)`
     keeps rank 1.
  3. The result is 1,000,000 rows, one per payment, with timestamps converted to UTC timestamps.
- **Query 3, turnover** (`06-q3-turnover-json.csv`, exact: integers in minor units then `/100`), success only, top
  three per currency:

  | Currency | Total turnover | Top merchants |
  | --- | --- | --- |
  | UAH | 726,040,513.31 ₴ (874,273 payments) | Інтернет-магазин 310,259,259.21, АЗС 144,641,341.06, Квитки 77,749,863.65 |
  | USD | 31,656,774.19 $ (37,469 payments) | Інтернет-магазин 13,840,942.83, АЗС 5,856,481.33, Квитки 3,602,313.89 |
  | EUR | 23,400,058.37 € (28,078 payments) | Інтернет-магазин 10,084,500.30, АЗС 4,708,258.32, Квитки 2,451,613.23 |

  All 30 merchant × currency rows are in the CSV. The average payment per merchant is the same
  across currencies: the dataset uses one price list per merchant.
- **Query 4, failure rate** (`07-q4-failure-rate-json.csv`). Every payment has finished. Overall 60,180 of
  1,000,000 failed, **6.02%**. The rate is flat across methods and devices: from **6.71% (QR on Android)**
  through 6.13% (Apple Pay on Android) and 6.08% (Google Pay on web) down to 5.92% (QR on iOS). QR has
  only about 6,700 payments per device, so its ±0.3 pp is within noise. The generator draws failures
  independently of method and device, and the query shows it.
- **Query 5, peak hours** (`08-q5-peak-hours-json.csv`, Kyiv local time).
  - The quietest hours are 03:00–07:00, about 0.7% of payments each.
  - Payments rise from 09:00 and peak in the evening: **21:00 = 7.87%**, 20:00 = 7.47%, 22:00 = 7.07%.
  - There is a second, smaller peak at 15:00 (6.53%).
  - The data is in UTC; the hours are shifted to Kyiv, and the shift accounts for daylight saving ending on 25 October.
- **Query 6, late events:** 2.01% of events arrived more than 60 s after they happened, none more than 600 s.
- **Query 7, Parquet:** `CREATE TABLE payments_parquet WITH (format='PARQUET', write_compression='SNAPPY',
  external_location='s3://…/curated/payments/', partitioned_by=ARRAY['dt']) AS SELECT … FROM payments`.
  Queries 3–5 on it return **identical** CSVs (compared byte for byte).

### JSON against Parquet (`stats.md`, screenshot `athena-console-recent-queries.png`)

| Query | JSON (view over raw) | Parquet (curated) | Less data | Faster |
| --- | --- | --- | --- | --- |
| 3 turnover | 1,202.29 MB, 3.27 s | 6.09 MB, 1.42 s | **197×** | 2.3× |
| 4 failure rate | 1,202.29 MB, 3.37 s | 0.64 MB, 1.08 s | **1,878×** | 3.1× |
| 5 peak hours | 1,202.29 MB, 3.82 s | 8.10 MB, 1.14 s | **148×** | 3.4× |

**What it means for the bill.** Athena bills $5 per TB scanned with a 10 MB minimum per query. On
JSON, each of these queries costs $0.0060. On Parquet, each one bills the 10 MB minimum, $0.00005.
That is **120 times cheaper** per query at this size, and **150–1,900 times** less data, which is
what matters once the data is larger than the minimum. Each query also skips the deduplication,
because it was done once in the curated layer.

Parquet wins in three ways:
- it is columnar, so a query reads only the columns it uses;
- it is compressed with dictionary encoding (status, method and device have a handful of values);
- it is binary, so there is no JSON parsing.

### Way B: Glue crawler (`crawler-schema.md`, `14-way-b-crawled-table.csv`)

The crawler ran in 44 s and created `crawled_payments`: classification `json`, the same OpenX SerDe,
**`dt` recognised as a partition** (string, all 31 partitions registered).

- **Types.**
  - `amount` and `finalAmount` became **int**, not bigint. The largest amount in the month is 8,004,389
    minor units, well below 2³¹, but one payment over 21.4 M ₴ would not fit, and the crawler does not
    know that.
  - `ccy` and `mcc` became int.
  - **All three dates are strings.** The crawler does not recognise ISO 8601 with `T` and `Z` as a
    timestamp, so every query has to convert them.
- **`failureReason`** is a normal nullable string column. The crawler merged the schemas of all
  files, and the field appears in some events. It is NULL in the 2,969,418 events without it and
  filled in all 60,779 failure events. If the crawler had sampled only files or rows without failures,
  the column would be missing until a later crawl, and the schema would change under the queries.
- **Which is more convenient, and why hand-written schemas are still common.** The crawler is fast to
  start and follows new fields by itself. The hand-written table is the contract:
  - exact types (`bigint` money, comments, units);
  - columns that exist even when today's data lacks them;
  - no surprise type changes after a crawl (an `int` that becomes `bigint` or `string` breaks views
    and Parquet writers);
  - it lives in Git and goes through review;
  - no crawler bill or schedule.

  Teams often crawl once to get a draft, then pin the schema in code (here: SQL in Git, or Terraform
  as for `stream_payments`).

### Why DISTINCT comes before row_number(), and what breaks without deduplication

`DISTINCT` removes exact copies before ranking. Then every remaining row of an invoice is a different
event, and `row_number()` chooses among real events only:
- The choice is deterministic: with the tie-breakers, the same input always gives the same row. Two
  identical copies of the latest event would otherwise compete for rank 1, and nothing would show that a
  duplicate existed.
- The window sorts 1% fewer rows.
- Any event-level number computed from the same CTE (late events, events per payment) is correct.

The order matters in the other direction too. Ranking first and then removing duplicates would still leave
one row per invoice, but the event counts and the evidence of how many duplicates there were would be wrong.

Without deduplication:
- every payment is counted about three times (once per status);
- the 1% duplicated success events double their turnover;
- a payment with a duplicate failure counts twice in the failure rate;
- peak hours count events, not payments;
- `COUNT(DISTINCT invoiceId)` hides the problem in totals but not in sums.

The latest-status step is the other half. Without it, a payment that failed after processing is
counted as processing too.

## Part 3: Streaming in the cloud

**Pipeline** (`lab8-runs/part3/pipeline-diagram.png`): the same payments dataset, replayed as a live webhook
feed.

1. **Producer** (`producer.py`). It reads one day (2026-10-01: 101,084 events) from our bucket and
   sorts by `receivedAt`, so late events arrive late and duplicates arrive twice, as in reality. It
   sends with `PutRecords` in batches of 500 at 800 records/s. The partition key is `invoiceId`, so
   all events of a payment go to the same shard in order. Throttled records are retried with
   exponential backoff. It adds `producedAt` and a `drill` flag.
2. **Kinesis Data Streams**: 1 provisioned shard, 24 h retention, KMS encryption. The stream decouples
   the producer from the consumers, keeps the order per payment, and lets two independent readers
   consume and replay the same data.
3. **Data Firehose**:
   - reads the stream;
   - converts JSON to **Parquet (Snappy)** with the schema of the Glue table `stream_payments`;
   - uses **dynamic partitioning by event time** (JQ `{dt: .modifiedDate[0:10]}` →
     `stream/dt=2026-10-01/`), so the stream table lines up with the batch table;
   - buffers 60 s / 64 MB;
   - sends failed records to `stream-errors/`.
4. **S3 + Glue + Athena.** `stream_payments` uses partition projection: no crawler and no
   `MSCK REPAIR` after Firehose writes.
5. **Alert:**
   - a Lambda on the same stream with a **60-second tumbling window**, where Lambda keeps the window's
     state between batches;
   - per window it counts finished payments per merchant, each invoice once;
   - when a merchant with at least 50 payments fails more than 30% of them, it publishes to **SNS**,
     which emails the alert.

**The run (24 Nov 2026, 22:00–22:03 UTC).**
- 101,084 records sent in 126 s (800/s), 48.3 MB, **0 throttled, 0 errors**.
- To test the alert, an **incident drill** turned every finished payment of merchant m-003 (Таксі) into
  a failure for 75 s (2,072 events, marked `drill = true`).
- The alerter's windows (`alerter-windows.jsonl`):

  | Window (processing time) | Finished payments | Failed | Alert |
  | --- | --- | --- | --- |
  | 22:00–22:01 | 5,771 | 366 (6.3%) | none |
  | 22:01–22:02 | 15,836 | 1,913 | **Таксі** |
  | 22:02–22:03 | 11,754 | 1,642 | **Таксі** |

- The email said: *"[lab8] payment failures above 30%: Таксі — Таксі: 1077 of 1641 payments failed (66%);
  Acquirer unavailable (drill): 1040; Невірний CVV: 10; Перевищено ліміт: 9"* (screenshot `lab8-runs/part3/sns-alert-email.png`).

**Athena over the data that came through the stream** (`sql/part3`, screenshot `athena-console-stream-query.png`).
- *Everything arrived* (`02-stream-vs-batch.csv`). The stream partition `dt=2026-10-01` holds **101,084 events,
  33,361 payments, 100,083 distinct events**. The batch partition of the same day has exactly the same
  three numbers: nothing was lost or duplicated by the pipeline.
- *The alert, checked in SQL* (`03-failure-rate-by-merchant.csv`). Таксі has 63.95% failed in the stream
  (2,060 of them from the drill); without the drill rows it is 6.08%, like every other merchant
  (5.2–6.4%).
- *Latency* (`04-end-to-end-delay.csv`). One Parquet file (5.2 MB) was written 45 s after the last
  event was sent: the Firehose buffer. The speed road answers in about a minute; the alert answers at
  the end of its window.

**What each managed service does for me.**
- **Kinesis Data Streams** is a durable, ordered, replayable log with no brokers to run. AWS handles
  replication across three AZs, storage, encryption, and scaling by shards.
- **Data Firehose** is delivery without code. It does batching, retries, Parquet conversion against a
  schema, partitioning by a field of the record, compression and error files. Doing this myself means a
  consumer fleet with checkpointing, a Parquet writer and small-file management.
- **Lambda** runs consumer code without servers. The event source mapping polls the shard, checkpoints,
  retries, bisects bad batches, and keeps window state.
- **SNS** handles fan-out to email (or SMS or webhooks) and delivery retries.
- **Glue Data Catalog** is one schema shared by Firehose (for Parquet) and Athena (for SQL).
- **Athena** is SQL on files in S3 with no cluster, paid per byte read.

### What it cost

Measured usage at list prices (us-east-1):

| Service | Usage | Cost |
| --- | --- | --- |
| Kinesis Data Streams | 1 shard × ~0.5 h ($0.015/shard-h); 101,084 PUT payload units ($0.014/M) | $0.009 |
| Data Firehose | 101,084 records, billed in 5 KB steps = 0.51 GB ingested ($0.029/GB); format conversion ($0.018/GB); dynamic partitioning (48 MB × $0.02/GB, 1 object, seconds of JQ) | $0.025 |
| Lambda | ~60 invocations, seconds of 256 MB | $0 (free tier) |
| SNS | 2 emails | $0 (free tier) |
| Athena | 36 queries, 17.76 GB scanned (Part 2, exploration, Part 3) | $0.089 |
| Glue crawler | 1 run, 44 s (billed per second, 10-minute minimum, about 2 DPU) | ≈ $0.15 |
| S3 | ~1.4 GB stored (raw copy, Parquet, stream), requests; the in-region copy is free | ≈ $0.03 / month |
| **Total** | | **≈ $0.30** |

The stream and Firehose were deleted right after the run (`make -C lab8 stream-off`, 22:30 UTC), so
nothing bills by the hour any more. The bucket and tables stay for the review.

**If the pipeline ran all month at this volume** (3 M events, about 1.2 per second on average):
- Kinesis is 1 shard × 730 h = $10.95.
- Firehose is about $1.2 (15 GB billed + conversion + about 44,000 objects).
- Lambda is about 44,000 invocations, still free tier.
- S3 is about $0.1.
- That is **≈ $12 a month, 90% of it the shard-hour**.

On-demand Kinesis would be $29 or more. If no second consumer were needed, Firehose with Direct PUT
(no Kinesis) would bring it down to about $1.5, but there would be no replay and no real-time
consumer. Athena then costs per query: on Parquet, cents a month.

## What we discuss in class

**Event time against processing time, and late events.**
- Event time is when the payment changed status (`modifiedDate`). Processing time is when we learned of
  it (`receivedAt`, or when Firehose or Lambda saw it).
- Here 2% of events are 1–10 minutes late. Two choices in this lab show the difference.
  - *Firehose partitions by event time* (`dt = modifiedDate`). A late event still lands in its own day,
    and batch and stream agree. Partitioning by arrival time would put a 23:58 payment that arrived at
    00:03 into the next day's partition.
  - *The alert windows are processing-time windows* (Lambda's tumbling window). They are simple and
    fast, but a late event is counted in the window when it arrived, not when it happened.
- For per-minute business metrics, a stream processor such as Flink uses **event-time windows with
  watermarks** (for example, wait 10 minutes, the maximum lateness here) and a rule for events later than
  that: drop them, or send them to a side output that corrects the result later.
- The batch road has no lateness problem: by the night run, everything has arrived. That is why the
  nightly batch stays the source of truth for money.

**Why the same raw data is kept twice, as JSON and as Parquet.**
- The raw JSON is the immutable record of what arrived, duplicates and all. If the deduplication rule,
  the schema or a bug changes, the curated layer can be rebuilt from it. It is also evidence for audits
  and disputes.
- Parquet is the curated, deduplicated, typed copy optimised for reading: 150–1,900 times less data per
  query here.
- Storage is cheap (the Parquet copy is a few percent of the JSON). Re-reading raw JSON for every
  query is not. A lifecycle rule can move old raw data to colder storage classes.

**When a nightly batch is enough, and when seconds are needed.**
- Seconds matter when the decision is made during the interaction, and a late answer is worth
  nothing: matching, surge, fraud blocking, an acquirer outage (the alert above found one in about a
  minute), a payment that must not be charged twice.
- A nightly batch is enough when the consumer is a person or a process that runs daily: finance
  reports, payouts, product analytics, model training, reconciliation with the bank.
- The cost difference is large. Here the stream is a fixed $11 a month even when idle, and batch is
  cents per query.
- Many teams run both. The speed road gives a fast, approximate answer, and the batch road gives the
  correct one (the lambda architecture).

**What a managed service gives over running Kafka and Spark yourself, and what it costs.**
- Kinesis, Firehose and Glue/Athena remove the operations:
  - no brokers, ZooKeeper/KRaft, disks, rebalancing or upgrades;
  - no Spark cluster sized for the peak;
  - replication, patching and scaling are AWS's;
  - IAM, CloudWatch and per-use billing come with it.
  For a small team that is most of the work.
- What you give up:
  - limits: shard throughput, 1 MB records, retention, and Firehose's 64 MB minimum buffer with
    conversion;
  - less control: Kafka features such as compaction, exactly-once transactions and the connector
    ecosystem; Spark's tuning;
  - lock-in, and a price per unit that becomes more expensive than self-hosting at high constant
    volume (a shard-hour costs the same idle or busy).
- Managed Kafka (MSK) and Managed Flink sit in between: the same APIs, a cluster you pay for by the hour.

## Notes
- Clean-up: `make -C lab8 stream-off` (done) removes everything that bills by the hour. `make -C lab8 destroy`
  removes the rest, the bucket included.
- The incident drill is the only change to the data in Part 3, and every drilled row has `drill = true`.
