# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Way B: run the Glue crawler over payments/ and compare its schema with the hand-written table.

Writes ../docs/lab8-runs/part2/crawler-schema.md (side by side) and crawler-table.json (raw Glue output).
"""

import json
import pathlib
import time

import boto3

glue = boto3.client("glue")
CRAWLER, DB = "ooad-lab8-payments", "lab8_payments"
OUT = pathlib.Path("../docs/lab8-runs/part2")

started = time.time()
try:
    glue.start_crawler(Name=CRAWLER)
except glue.exceptions.CrawlerRunningException:
    pass
time.sleep(5)
while glue.get_crawler(Name=CRAWLER)["Crawler"]["State"] != "READY":
    time.sleep(10)
crawler = glue.get_crawler(Name=CRAWLER)["Crawler"]
last = crawler.get("LastCrawl", {})
print(f"crawler {last.get('Status')} in {time.time() - started:.0f} s (wall clock); {last.get('ErrorMessage', '')}")

tables = [t["Name"] for t in glue.get_tables(DatabaseName=DB)["TableList"]]
crawled = next(t for t in tables if t.startswith("crawled_"))
auto = glue.get_table(DatabaseName=DB, Name=crawled)["Table"]
hand = glue.get_table(DatabaseName=DB, Name="payment_events")["Table"]
parts = glue.get_partitions(DatabaseName=DB, TableName=crawled)["Partitions"]

(OUT / "crawler-table.json").write_text(json.dumps(auto, indent=2, default=str, ensure_ascii=False))

hand_cols = {c["Name"]: c["Type"] for c in hand["StorageDescriptor"]["Columns"]}
auto_cols = {c["Name"]: c["Type"] for c in auto["StorageDescriptor"]["Columns"]}
lines = [
    (
        f"Crawler table `{crawled}`: classification `{auto['Parameters'].get('classification')}`, "
        f"SerDe `{auto['StorageDescriptor']['SerdeInfo'].get('SerializationLibrary')}`, "
        f"partition keys {[(k['Name'], k['Type']) for k in auto.get('PartitionKeys', [])]}, "
        f"{len(parts)} partitions registered, records sampled: {auto['Parameters'].get('recordCount', '?')}, "
        f"last crawl {last.get('Status')}."
    ),
    "",
    "| column | hand-written (payment_events) | crawler (" + crawled + ") |",
    "|---|---|---|",
]
for name in list(hand_cols) + [n for n in auto_cols if n not in hand_cols]:
    lines.append(f"| {name} | {hand_cols.get(name, '—')} | {auto_cols.get(name, '— (missing)')} |")
for k in auto.get("PartitionKeys", []):
    lines.append(f"| {k['Name']} (partition) | string | {k['Type']} |")
(OUT / "crawler-schema.md").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
