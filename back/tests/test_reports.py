import csv
import io
import json
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.reports import weekly
from app.reports.lambda_handler import handler, parse_report_event
from app.reports.weekly import build_weekly_report, get_week_bounds, parse_iso_week
from tests.conftest import TestingSession

KYIV_TZ = ZoneInfo("Europe/Kyiv")


@pytest.fixture(autouse=True)
def use_testing_session(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(weekly, "SessionLocal", TestingSession)
    monkeypatch.setattr(settings, "cognito_user_pool_id", "")


def _create_participant(client: TestClient, name: str, email: str) -> str:
    resp = client.post("/api/participants", json={"name": name, "email": email})
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def _create_meeting(
    client: TestClient,
    title: str,
    starts_at: str,
    ends_at: str,
    participant_ids: list[str] | None = None,
) -> dict:
    resp = client.post(
        "/api/meetings",
        json={
            "title": title,
            "description": "Weekly report test meeting",
            "call_link": "https://meet.google.com/abc-defg-hij",
            "place": "Room 101",
            "starts_at": starts_at,
            "ends_at": ends_at,
            "participant_ids": participant_ids or [],
        },
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_parse_iso_week_and_bounds():
    monday = parse_iso_week("2026-W41")
    assert monday.isoformat() == "2026-10-05"

    start, end, prev_week, prev_start, prev_end = get_week_bounds("2026-W41")
    assert prev_week == "2026-W40"
    assert start == datetime(2026, 10, 5, 0, 0, tzinfo=KYIV_TZ)
    assert end == datetime(2026, 10, 12, 0, 0, tzinfo=KYIV_TZ)
    assert prev_start == datetime(2026, 9, 28, 0, 0, tzinfo=KYIV_TZ)
    assert prev_end == start

    with pytest.raises(ValueError, match="Invalid ISO week"):
        parse_iso_week("2026-41")
    with pytest.raises(ValueError, match="Invalid ISO week"):
        parse_iso_week("2026-W54")


def test_build_weekly_report_counts_hours_top5_and_determinism(client: TestClient):
    anna_id = _create_participant(client, "Anna", "anna@example.com")
    oleh_id = _create_participant(client, "Oleh", "oleh@example.com")

    # Previous week (2026-W40: 2026-09-28 .. 2026-10-04 Europe/Kyiv): 1 meeting, 1.5h
    _create_meeting(
        client,
        "W40 Planning",
        "2026-09-29T10:00:00+03:00",
        "2026-09-29T11:30:00+03:00",
        [anna_id],
    )

    # Boundary check: Sunday 23:30 UTC on 2026-10-04 is Monday 02:30+03:00 on 2026-10-05 in Kyiv (W41)
    _create_meeting(
        client,
        "Kyiv Monday Early Sync",
        "2026-10-04T23:30:00Z",
        "2026-10-05T00:30:00Z",
        [anna_id, oleh_id],
    )

    # 5 more meetings in 2026-W41 with different durations to verify top-5 cap & sorting
    _create_meeting(client, "Architecture Review", "2026-10-06T09:00:00+03:00", "2026-10-06T11:00:00+03:00")
    _create_meeting(
        client,
        "Sprint Demo",
        "2026-10-07T14:00:00+03:00",
        "2026-10-07T15:30:00+03:00",
        [anna_id],
    )
    _create_meeting(client, "1-on-1", "2026-10-08T10:00:00+03:00", "2026-10-08T10:45:00+03:00")
    _create_meeting(client, "Retro", "2026-10-09T16:00:00+03:00", "2026-10-09T17:15:00+03:00")
    _create_meeting(client, "Quick Standup", "2026-10-09T09:00:00+03:00", "2026-10-09T09:15:00+03:00")

    csv_first = build_weekly_report("2026-W41")
    csv_second = build_weekly_report("2026-W41")
    assert csv_first == csv_second

    rows = list(csv.reader(io.StringIO(csv_first.decode("utf-8"))))
    assert rows[0] == [
        "week",
        "meetings_count",
        "total_hours",
        "previous_week",
        "previous_meetings_count",
        "previous_total_hours",
        "meetings_diff",
        "hours_diff",
    ]
    assert rows[1] == ["2026-W41", "6", "6.75", "2026-W40", "1", "1.50", "5", "5.25"]

    assert rows[3] == ["owner_email", "meetings_count", "total_hours"]
    assert rows[4] == ["dev@localhost", "6", "6.75"]

    assert rows[6] == ["rank", "title", "starts_at", "duration_minutes", "participants_count", "owner_email"]
    top_rows = rows[7:]
    assert len(top_rows) == 5
    assert [r[1] for r in top_rows] == [
        "Architecture Review",
        "Sprint Demo",
        "Retro",
        "Kyiv Monday Early Sync",
        "1-on-1",
    ]
    assert [r[3] for r in top_rows] == ["120", "90", "75", "60", "45"]


def test_parse_report_event_variants():
    trigger, weeks = parse_report_event({"trigger": "schedule", "week": "2026-W41"})
    assert trigger == "schedule"
    assert weeks == ["2026-W41"]

    sqs_event = {"Records": [{"eventSource": "aws:sqs", "body": json.dumps({"week": "2026-W40"})}]}
    trigger, weeks = parse_report_event(sqs_event)
    assert trigger == "sqs"
    assert weeks == ["2026-W40"]

    trigger, weeks = parse_report_event({"week": "2026-W39"})
    assert trigger == "direct"
    assert weeks == ["2026-W39"]


def test_lambda_handler_uploads_fixed_s3_key(client: TestClient, monkeypatch: pytest.MonkeyPatch):
    _create_meeting(client, "Sync", "2026-10-06T10:00:00+03:00", "2026-10-06T11:00:00+03:00")
    monkeypatch.setenv("REPORTS_BUCKET", "test-reports-bucket")

    uploads: list[dict] = []

    class FakeS3:
        def put_object(self, **kwargs):
            uploads.append(kwargs)

    sqs_event = {"Records": [{"eventSource": "aws:sqs", "body": '{"week": "2026-W41"}'}]}
    result = handler(sqs_event, None, s3_client=FakeS3())
    assert result["status"] == "ok"
    assert result["trigger"] == "sqs"
    assert len(uploads) == 1
    assert uploads[0]["Bucket"] == "test-reports-bucket"
    assert uploads[0]["Key"] == "reports/2026-W41.csv"
    assert b"2026-W41" in uploads[0]["Body"]
