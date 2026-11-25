# Lab 8: Big Data on AWS (payments lake and stream)

The report with every answer, result and cost is in [docs/lab8-report.md](../docs/lab8-report.md).

```
infra/      Terraform: the lake bucket, Athena workgroup, Glue database and crawler (Part 2);
            Kinesis, Firehose (Parquet, event-time partitions), the alert Lambda and SNS (Part 3)
sql/part2/  Way A: table, partitions, dedup view, queries 3-6, CTAS to Parquet, queries 3-5 on Parquet; Way B check
sql/part3/  queries over the data that came through the stream
sql/explore/ what dt means, what a duplicate looks like
producer/   producer.py: replays one day of webhooks into Kinesis (rate limit, retries, incident drill)
alerter/    handler.py: tumbling-window failure-rate alert -> SNS
scripts/    athena.py (runs a SQL folder, saves CSV + scanned bytes + time), crawl.py (Way B),
            console_url.py (one-hour console sign-in limited to Lab 8, for screenshots)
diagram/    pipeline.html -> ../docs/lab8-runs/part3/pipeline-diagram.png
```

```bash
make -C lab8 init up copy     # Terraform, then copy the dataset (S3 -> S3, same region, free)
make -C lab8 part2 crawl      # Way A queries, then Way B
make -C lab8 stream-on        # Kinesis + Firehose + alert consumer (billed per hour)
make -C lab8 produce DRILL=1  # replay 2026-10-01 at 800/s with the incident drill
make -C lab8 part3            # Athena over the stream's Parquet
make -C lab8 stream-off       # delete the stream and Firehose; the data stays
make -C lab8 destroy          # delete everything, the bucket included
```

The alert email address is `LAB8_ALERT_EMAIL` in `.env` (passed as `TF_VAR_alert_email`, never committed).
This is a lab sandbox, applied from a laptop with its own state (`lab8/terraform.tfstate` in the
project's state bucket); the product's infrastructure in `infra/` still changes only through the pipeline.
