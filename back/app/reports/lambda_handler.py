"""AWS Lambda entry point for the weekly report builder (EventBridge Scheduler, SQS, or direct)."""

import json
import os
from typing import Any

from app.reports.weekly import build_weekly_report, current_previous_iso_week, parse_iso_week


def parse_report_event(event: dict[str, Any]) -> tuple[str, list[str]]:
    """Extract (trigger_type, weeks) from an SQS, EventBridge Scheduler, or direct Lambda event."""
    records = event.get("Records")
    if isinstance(records, list) and records:
        first_source = records[0].get("eventSource") or records[0].get("EventSource")
        if first_source == "aws:sqs":
            weeks: list[str] = []
            for record in records:
                raw_body = record.get("body", "{}")
                body = json.loads(raw_body) if isinstance(raw_body, str) and raw_body.strip() else {}
                if not isinstance(body, dict):
                    raise ValueError(f"SQS message body must be a JSON object, got: {raw_body!r}")
                if body.get("fail"):
                    raise RuntimeError(f"Simulated builder failure requested in message: {body!r}")
                week = body.get("week") or current_previous_iso_week()
                parse_iso_week(week)
                weeks.append(week)
            return "sqs", weeks

    if (
        event.get("trigger") == "schedule"
        or event.get("source") in ("aws.scheduler", "aws.events")
        or event.get("detail-type") == "Scheduled Event"
    ):
        week = event.get("week") or current_previous_iso_week()
        parse_iso_week(week)
        return "schedule", [week]

    if event.get("fail"):
        raise RuntimeError(f"Simulated builder failure requested in event: {event!r}")
    week = event.get("week") or current_previous_iso_week()
    parse_iso_week(week)
    return "direct", [week]


def _upload_report(bucket: str, key: str, data: bytes, s3_client: Any = None) -> None:
    if s3_client is None:
        import boto3

        s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=bucket,
        Key=key,
        Body=data,
        ContentType="text/csv; charset=utf-8",
    )


def handler(event: dict[str, Any], context: Any, s3_client: Any = None) -> dict[str, Any]:
    """Build weekly report(s) and upload to s3://<REPORTS_BUCKET>/reports/<week>.csv."""
    trigger, weeks = parse_report_event(event)
    print(f"trigger={trigger} weeks={','.join(weeks)}")

    fail_on_week = os.getenv("FAIL_ON_WEEK", "").strip()
    bucket = os.environ["REPORTS_BUCKET"]
    uploaded: list[dict[str, Any]] = []

    for week in weeks:
        if fail_on_week and week == fail_on_week:
            raise RuntimeError(f"Simulated failure for week={week} via FAIL_ON_WEEK")
        csv_bytes = build_weekly_report(week)
        key = f"reports/{week}.csv"
        size = len(csv_bytes)
        _upload_report(bucket, key, csv_bytes, s3_client=s3_client)
        print(f"trigger={trigger} status=uploaded week={week} bucket={bucket} key={key} bytes={size}")
        uploaded.append({"week": week, "bucket": bucket, "key": key, "size": size})

    return {"status": "ok", "trigger": trigger, "reports": uploaded}
