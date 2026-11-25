"""Lab 8, Part 3: the alert consumer of the payments stream.

Kinesis calls this function with a tumbling window (60 s by default). Lambda keeps the window's
`state` between invocations; the last call of a window has `isFinalInvokeForWindow`. Per window it
counts finished payments (success or failure) per merchant, once per invoiceId (the stream has
duplicates), and publishes one SNS message when a merchant with enough payments fails more often
than the threshold. Every window also writes one JSON log line, so the alert can be checked later.
"""

import base64
import json
import os

import boto3

sns = boto3.client("sns")

TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
THRESHOLD = float(os.environ.get("FAILURE_RATE_THRESHOLD", "0.3"))
MIN_PAYMENTS = int(os.environ.get("ALERT_MIN_PAYMENTS", "50"))


def handler(event, context):
    state = event.get("state") or {"seen": [], "merchants": {}}
    seen = set(state["seen"])
    merchants = state["merchants"]

    for record in event.get("Records", []):
        payment = json.loads(base64.b64decode(record["kinesis"]["data"]))
        if payment.get("status") not in ("success", "failure"):
            continue
        key = f"{payment['invoiceId']}:{payment['status']}"
        if key in seen:  # a duplicate delivery of the same webhook
            continue
        seen.add(key)
        m = merchants.setdefault(payment["merchantName"], {"finished": 0, "failed": 0, "reasons": {}})
        m["finished"] += 1
        if payment["status"] == "failure":
            m["failed"] += 1
            reason = payment.get("failureReason") or "unknown"
            m["reasons"][reason] = m["reasons"].get(reason, 0) + 1

    if not event.get("isFinalInvokeForWindow"):
        return {"state": {"seen": sorted(seen), "merchants": merchants}}

    window = event.get("window", {})
    alerts = []
    for name, m in sorted(merchants.items()):
        rate = m["failed"] / m["finished"] if m["finished"] else 0.0
        m["failure_rate"] = round(rate, 4)
        if m["finished"] >= MIN_PAYMENTS and rate > THRESHOLD:
            alerts.append((name, m))

    print(
        json.dumps(
            {
                "event": "payments_window",
                "window_start": window.get("start"),
                "window_end": window.get("end"),
                "shard": event.get("shardId"),
                "finished": sum(m["finished"] for m in merchants.values()),
                "failed": sum(m["failed"] for m in merchants.values()),
                "alerts": [name for name, _ in alerts],
                "merchants": merchants,
            },
            ensure_ascii=False,
        )
    )

    if alerts:
        lines = [
            f"Window {window.get('start')} - {window.get('end')} (processing time), threshold {THRESHOLD:.0%}:",
            "",
        ]
        for name, m in alerts:
            top = sorted(m["reasons"].items(), key=lambda kv: -kv[1])[:3]
            lines.append(
                f"- {name}: {m['failed']} of {m['finished']} payments failed ({m['failure_rate']:.0%}); "
                + "; ".join(f"{r}: {n}" for r, n in top)
            )
        sns.publish(
            TopicArn=TOPIC_ARN,
            Subject=f"[lab8] payment failures above {THRESHOLD:.0%}: " + ", ".join(n for n, _ in alerts),
            Message="\n".join(lines),
        )

    return {}
