# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Lab 8, Part 3: the producer. Replays one day of payment webhooks into a Kinesis data stream.

It plays the role of the merchant's webhook endpoint: every payment status change becomes one record.

- Order: by receivedAt, the moment the webhook reached us (processing time), so late events arrive
  late here too, and the ~1% duplicates are sent twice, as in the source.
- Partition key: invoiceId. All events of one payment go to the same shard, in order.
- Rate: --rate records per second (one shard accepts up to 1,000 records or 1 MB per second).
- PutRecords in batches of up to 500; records the stream throttles are retried with backoff.
- Each record gets producedAt (when we sent it) and drill (false).
- --drill: an incident drill for the alert. For --drill-seconds, starting --drill-after seconds into the
  replay, every finished payment of --drill-merchant is sent as a failure ("Acquirer unavailable
  (drill)") with drill = true. The alert consumer should fire; the drill rows stay identifiable.

usage: uv run producer/producer.py --stream ooad-lab8-payments --day 2026-10-01 [--rate 800] [--drill] [--limit N]
"""

import argparse
import json
import random
import sys
import time
from datetime import UTC, datetime

import boto3

MAX_BATCH = 500


def load_day(s3, bucket: str, day: str) -> list[dict]:
    body = s3.get_object(Bucket=bucket, Key=f"payments/dt={day}/events.jsonl")["Body"]
    events = [json.loads(line) for line in body.iter_lines() if line.strip()]
    events.sort(key=lambda e: e["receivedAt"])  # stable: duplicates keep their order
    return events


def put_with_retries(kinesis, stream: str, records: list[dict], stats: dict) -> None:
    attempt = 0
    while records:
        resp = kinesis.put_records(StreamName=stream, Records=records)
        if resp["FailedRecordCount"] == 0:
            return
        failed = [r for r, res in zip(records, resp["Records"]) if "ErrorCode" in res]
        for res in resp["Records"]:
            if "ErrorCode" in res:
                stats["errors"][res["ErrorCode"]] = stats["errors"].get(res["ErrorCode"], 0) + 1
        stats["retried"] += len(failed)
        attempt += 1
        if attempt > 8:
            raise RuntimeError(f"{len(failed)} records still failing after {attempt} attempts")
        time.sleep(min(2**attempt * 0.05, 2) + random.random() * 0.05)  # exponential backoff with jitter
        records = failed


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--stream", required=True)
    p.add_argument("--day", default="2026-10-01")
    p.add_argument("--bucket", help="default: ooad-lab8-<account id>")
    p.add_argument("--rate", type=int, default=800, help="records per second")
    p.add_argument("--limit", type=int, help="send only the first N events")
    p.add_argument("--drill", action="store_true")
    p.add_argument("--drill-merchant", default="m-003")
    p.add_argument("--drill-after", type=float, default=45.0)
    p.add_argument("--drill-seconds", type=float, default=75.0)
    p.add_argument("--summary", default="../docs/lab8-runs/part3/producer-run.json")
    args = p.parse_args()

    session = boto3.session.Session()
    s3, kinesis = session.client("s3"), session.client("kinesis")
    bucket = args.bucket or f"ooad-lab8-{session.client('sts').get_caller_identity()['Account']}"

    events = load_day(s3, bucket, args.day)
    if args.limit:
        events = events[: args.limit]
    print(
        f"loaded {len(events)} events of {args.day} from s3://{bucket}, replaying at {args.rate}/s into {args.stream}"
    )

    stats = {"sent": 0, "bytes": 0, "retried": 0, "errors": {}, "drill_events": 0}
    start = time.monotonic()
    started_at = datetime.now(UTC)
    for i in range(0, len(events), MAX_BATCH):
        # Pace: batch i may start no earlier than i / rate seconds after the start.
        wait = i / args.rate - (time.monotonic() - start)
        if wait > 0:
            time.sleep(wait)
        now = time.monotonic() - start
        in_drill = args.drill and args.drill_after <= now < args.drill_after + args.drill_seconds
        produced_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        records = []
        for e in events[i : i + MAX_BATCH]:
            e = dict(e, producedAt=produced_at, drill=False)
            if in_drill and e["merchantId"] == args.drill_merchant and e["status"] in ("success", "failure"):
                e.update(status="failure", finalAmount=0, failureReason="Acquirer unavailable (drill)", drill=True)
                stats["drill_events"] += 1
            data = json.dumps(e, ensure_ascii=False).encode("utf-8") + b"\n"
            stats["bytes"] += len(data)
            records.append({"Data": data, "PartitionKey": e["invoiceId"]})
        put_with_retries(kinesis, args.stream, records, stats)
        stats["sent"] += len(records)
        if (i // MAX_BATCH) % 20 == 0:
            print(f"  {stats['sent']:>7} sent, {now:6.1f} s{'  [drill]' if in_drill else ''}")

    elapsed = time.monotonic() - start
    summary = {
        "stream": args.stream,
        "day": args.day,
        "started_at": started_at.isoformat(),
        "elapsed_s": round(elapsed, 1),
        "records_per_s": round(stats["sent"] / elapsed, 1),
        "megabytes": round(stats["bytes"] / 1e6, 2),
        "drill": args.drill
        and {"merchant": args.drill_merchant, "after_s": args.drill_after, "seconds": args.drill_seconds},
        **stats,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.summary:
        from pathlib import Path

        Path(args.summary).parent.mkdir(parents=True, exist_ok=True)
        Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
