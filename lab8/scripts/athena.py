# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Run every .sql file of a folder in Athena, in name order, and keep the evidence.

usage: uv run scripts/athena.py <sql-dir> <out-dir> [only-prefix]

For each file NN-name.sql: ${BUCKET} is replaced with the lab bucket, the query runs in the
ooad-lab8 workgroup, and <out-dir>/NN-name.csv gets the result (for queries that return rows).
<out-dir>/stats.md and stats.json collect state, Data scanned and run time of every query.
A line "-- clean: <prefix>" deletes that prefix of the bucket first (CTAS needs an empty location).
"""

import csv
import io
import json
import pathlib
import subprocess
import sys
import time

import boto3

WORKGROUP = "ooad-lab8"
DATABASE = "lab8_payments"

athena = boto3.client("athena")
s3 = boto3.client("s3")


def bucket_name() -> str:
    out = subprocess.run(
        ["terraform", "-chdir=infra", "output", "-raw", "bucket"], capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


def clean_prefix(bucket: str, prefix: str) -> int:
    deleted = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        keys = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if keys:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": keys})
            deleted += len(keys)
    return deleted


def run(sql: str) -> dict:
    qid = athena.start_query_execution(
        QueryString=sql, WorkGroup=WORKGROUP, QueryExecutionContext={"Database": DATABASE}
    )["QueryExecutionId"]
    while True:
        q = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        if q["Status"]["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return q
        time.sleep(1)


def fetch_csv(q: dict) -> str | None:
    if q.get("StatementType") != "DML":
        return None
    loc = q["ResultConfiguration"]["OutputLocation"]  # s3://bucket/key.csv
    bucket, key = loc[5:].split("/", 1)
    return s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")


def main() -> int:
    sql_dir, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    only = sys.argv[3] if len(sys.argv) > 3 else ""
    out_dir.mkdir(parents=True, exist_ok=True)
    bucket = bucket_name()
    stats_path = out_dir / "stats.json"
    stats = json.loads(stats_path.read_text()) if stats_path.exists() else {}

    for path in sorted(sql_dir.glob("*.sql")):
        if only and not path.name.startswith(only):
            continue
        sql = path.read_text().replace("${BUCKET}", bucket)
        for line in sql.splitlines():
            if line.startswith("-- clean: "):
                n = clean_prefix(bucket, line.removeprefix("-- clean: ").strip())
                print(f"   cleaned {n} objects under {line.removeprefix('-- clean: ').strip()}")
        body = "\n".join(line for line in sql.splitlines() if not line.startswith("--")).strip().rstrip(";")
        q = run(body)
        st = q["Statistics"]
        state = q["Status"]["State"]
        row = {
            "file": path.name,
            "state": state,
            "error": q["Status"].get("StateChangeReason", ""),
            "data_scanned_bytes": st.get("DataScannedInBytes", 0),
            "engine_ms": st.get("EngineExecutionTimeInMillis", 0),
            "total_ms": st.get("TotalExecutionTimeInMillis", 0),
            "query_id": q["QueryExecutionId"],
        }
        stats[path.stem] = row
        mb = row["data_scanned_bytes"] / 1024 / 1024
        print(f"{path.name:<34} {state:<9} {mb:10.2f} MB scanned {row['engine_ms'] / 1000:7.2f} s")
        if state != "SUCCEEDED":
            print("   ", row["error"])
            stats_path.write_text(json.dumps(stats, indent=2, ensure_ascii=False))
            return 1
        text = fetch_csv(q)
        if text is not None:
            (out_dir / f"{path.stem}.csv").write_text(text)
            rows = list(csv.reader(io.StringIO(text)))
            for r in rows[:12]:
                print("    " + " | ".join(r))
            if len(rows) > 12:
                print(f"    ... {len(rows) - 1} rows")

    stats_path.write_text(json.dumps(stats, indent=2, ensure_ascii=False))
    lines = ["| query | state | data scanned | engine time | total time |", "|---|---|---|---|---|"]
    for name, r in sorted(stats.items()):
        lines.append(
            f"| {r['file']} | {r['state']} | {r['data_scanned_bytes'] / 1024 / 1024:.2f} MB "
            f"| {r['engine_ms'] / 1000:.2f} s | {r['total_ms'] / 1000:.2f} s |"
        )
    (out_dir / "stats.md").write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
