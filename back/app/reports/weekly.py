"""Weekly meetings report builder (deterministic CSV in Europe/Kyiv ISO-week boundaries)."""

import csv
import io
import re
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.db import SessionLocal
from app.models import Meeting, User

KYIV_TZ = ZoneInfo("Europe/Kyiv")
WEEK_RE = re.compile(r"^(\d{4})-W(\d{2})$")


def current_previous_iso_week(now: datetime | None = None) -> str:
    """Return the ISO week string (YYYY-Www) for the week preceding `now` in Europe/Kyiv."""
    ref = (now or datetime.now(KYIV_TZ)).astimezone(KYIV_TZ)
    prev_day = ref.date() - timedelta(days=7)
    iso_year, iso_week, _ = prev_day.isocalendar()
    return f"{iso_year:04d}-W{iso_week:02d}"


def parse_iso_week(week: str) -> date:
    """Parse 'YYYY-Www' and return the Monday date of that ISO week."""
    match = WEEK_RE.fullmatch(week.strip())
    if not match:
        raise ValueError(f"Invalid ISO week format: {week!r} (expected YYYY-Www, e.g. 2026-W41)")
    year, week_num = int(match.group(1)), int(match.group(2))
    try:
        return date.fromisocalendar(year, week_num, 1)
    except ValueError as exc:
        raise ValueError(f"Invalid ISO week: {week!r}") from exc


def get_week_bounds(week: str) -> tuple[datetime, datetime, str, datetime, datetime]:
    """Return (start, end, prev_week, prev_start, prev_end) in Europe/Kyiv timezone."""
    monday = parse_iso_week(week)
    next_monday = monday + timedelta(days=7)
    prev_monday = monday - timedelta(days=7)
    prev_iso_year, prev_iso_week, _ = prev_monday.isocalendar()
    prev_week = f"{prev_iso_year:04d}-W{prev_iso_week:02d}"

    start = datetime.combine(monday, time.min, tzinfo=KYIV_TZ)
    end = datetime.combine(next_monday, time.min, tzinfo=KYIV_TZ)
    prev_start = datetime.combine(prev_monday, time.min, tzinfo=KYIV_TZ)
    prev_end = start
    return start, end, prev_week, prev_start, prev_end


def _duration_hours(meeting: Meeting) -> float:
    seconds = (meeting.ends_at - meeting.starts_at).total_seconds()
    return max(0.0, seconds / 3600.0)


def _duration_minutes(meeting: Meeting) -> int:
    seconds = (meeting.ends_at - meeting.starts_at).total_seconds()
    return max(0, round(seconds / 60.0))


def _load_meetings_in_range(db: Session, start: datetime, end: datetime) -> list[Meeting]:
    stmt = (
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .order_by(Meeting.starts_at, Meeting.id)
    )
    return list(db.scalars(stmt).all())


def _load_owner_emails(db: Session, meetings: list[Meeting]) -> dict[str, str]:
    owner_ids = {m.owner_id for m in meetings if m.owner_id is not None}
    if not owner_ids:
        return {}
    users = db.scalars(select(User).where(User.id.in_(owner_ids))).all()
    return {str(u.id): u.email for u in users}


def build_weekly_report(week: str, db: Session | None = None) -> bytes:
    """Build a deterministic UTF-8 CSV report for the given ISO week ('YYYY-Www')."""
    if db is None:
        with SessionLocal() as session:
            return build_weekly_report(week, db=session)

    start, end, prev_week, prev_start, prev_end = get_week_bounds(week)
    curr_meetings = _load_meetings_in_range(db, start, end)
    prev_meetings = _load_meetings_in_range(db, prev_start, prev_end)
    owner_emails = _load_owner_emails(db, curr_meetings)

    curr_count = len(curr_meetings)
    prev_count = len(prev_meetings)
    curr_hours = sum(_duration_hours(m) for m in curr_meetings)
    prev_hours = sum(_duration_hours(m) for m in prev_meetings)
    count_diff = curr_count - prev_count
    hours_diff = curr_hours - prev_hours

    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n")

    # 1. Summary section
    writer.writerow(
        [
            "week",
            "meetings_count",
            "total_hours",
            "previous_week",
            "previous_meetings_count",
            "previous_total_hours",
            "meetings_diff",
            "hours_diff",
        ]
    )
    writer.writerow(
        [
            week,
            curr_count,
            f"{curr_hours:.2f}",
            prev_week,
            prev_count,
            f"{prev_hours:.2f}",
            count_diff,
            f"{hours_diff:.2f}",
        ]
    )
    writer.writerow([])

    # 2. Per-owner breakdown (deterministic order by owner_email)
    writer.writerow(["owner_email", "meetings_count", "total_hours"])
    owner_stats: dict[str, tuple[int, float]] = {}
    for meeting in curr_meetings:
        owner_label = (
            owner_emails.get(str(meeting.owner_id), "unassigned")
            if meeting.owner_id is not None
            else "unassigned"
        )
        prev_cnt, prev_hrs = owner_stats.get(owner_label, (0, 0.0))
        owner_stats[owner_label] = (prev_cnt + 1, prev_hrs + _duration_hours(meeting))

    for owner_label in sorted(owner_stats):
        count_val, hours_val = owner_stats[owner_label]
        writer.writerow([owner_label, count_val, f"{hours_val:.2f}"])
    writer.writerow([])

    # 3. Top 5 longest meetings (deterministic tie-break: duration desc, starts_at asc, id asc)
    writer.writerow(["rank", "title", "starts_at", "duration_minutes", "participants_count", "owner_email"])
    ranked = sorted(
        curr_meetings,
        key=lambda m: (-_duration_minutes(m), m.starts_at.astimezone(KYIV_TZ), str(m.id)),
    )[:5]
    for idx, meeting in enumerate(ranked, start=1):
        owner_label = (
            owner_emails.get(str(meeting.owner_id), "unassigned")
            if meeting.owner_id is not None
            else "unassigned"
        )
        starts_kyiv = meeting.starts_at.astimezone(KYIV_TZ).isoformat()
        writer.writerow(
            [
                idx,
                meeting.title,
                starts_kyiv,
                _duration_minutes(meeting),
                len(meeting.participants),
                owner_label,
            ]
        )

    return buf.getvalue().encode("utf-8")
