import asyncio
import concurrent.futures
import csv
from datetime import datetime, timedelta, timezone
import io
import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.db import SessionLocal
from app.models import Meeting, User


def parse_iso_week(week_str: str) -> tuple[datetime, datetime]:
    """Parse an ISO week string like '2026-W41' into UTC datetime range [start, end).

    The range covers Monday 00:00:00 UTC up to (exclusive) the next Monday 00:00:00 UTC.
    """
    m = re.match(r"^(\d{4})-W(\d{2})$", week_str.strip())
    if not m:
        raise ValueError(f"Invalid ISO week format '{week_str}', expected 'YYYY-Wnn'")
    year, week_num = int(m.group(1)), int(m.group(2))
    if not (1 <= week_num <= 53):
        raise ValueError(f"Week number must be between 1 and 53, got {week_num}")

    # Monday of the given ISO week:
    start = datetime.strptime(f"{year}-W{week_num:02d}-1", "%G-W%V-%u").replace(
        tzinfo=timezone.utc
    )
    end = start + timedelta(days=7)
    return start, end


async def query_week_metrics(
    session: AsyncSession, start: datetime, end: datetime
) -> dict[str, Any]:
    """Query meetings and aggregate metrics for the given time range."""
    stmt = (
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.starts_at >= start, Meeting.starts_at < end)
        .order_by(Meeting.starts_at)
    )
    result = await session.execute(stmt)
    meetings = list(result.scalars().all())

    count = len(meetings)
    total_duration_hours = sum(
        (m.ends_at - m.starts_at).total_seconds() / 3600.0 for m in meetings
    )

    return {
        "meetings": meetings,
        "count": count,
        "total_duration_hours": total_duration_hours,
    }


async def generate_weekly_report(week: str, session: AsyncSession | None = None) -> bytes:
    """Async implementation of weekly report generation."""
    start, end = parse_iso_week(week)
    prev_start = start - timedelta(days=7)
    prev_end = start
    prev_year, prev_week_num, _ = prev_start.isocalendar()
    prev_week_str = f"{prev_year}-W{prev_week_num:02d}"

    async def _run(s: AsyncSession) -> bytes:
        curr_data = await query_week_metrics(s, start, end)
        prev_data = await query_week_metrics(s, prev_start, prev_end)

        curr_count = curr_data["count"]
        curr_hours = curr_data["total_duration_hours"]
        prev_count = prev_data["count"]
        prev_hours = prev_data["total_duration_hours"]

        count_diff = curr_count - prev_count
        hours_diff = curr_hours - prev_hours

        # Top 5 longest meetings in current week
        meetings = curr_data["meetings"]
        longest_meetings = sorted(
            meetings,
            key=lambda m: (m.ends_at - m.starts_at).total_seconds(),
            reverse=True,
        )[:5]

        # Organizer breakdown
        owner_ids = {m.owner_id for m in meetings if m.owner_id}
        users_by_id = {}
        if owner_ids:
            user_stmt = select(User).where(User.id.in_(owner_ids))
            user_res = await s.execute(user_stmt)
            for u in user_res.scalars().all():
                users_by_id[u.id] = u

        organizer_stats = {}
        for m in meetings:
            oid = m.owner_id
            if oid not in organizer_stats:
                user = users_by_id.get(oid)
                organizer_stats[oid] = {
                    "name": user.name if user else "Unknown",
                    "email": user.email if user else "unknown@example.com",
                    "count": 0,
                    "hours": 0.0,
                }
            organizer_stats[oid]["count"] += 1
            dur = (m.ends_at - m.starts_at).total_seconds() / 3600.0
            organizer_stats[oid]["hours"] += dur

        # Build CSV
        output = io.StringIO()
        writer = csv.writer(output)

        # Header / Meta
        writer.writerow(
            [
                "Weekly Meetings Report",
                f"Week: {week}",
                f"Start: {start.isoformat()}",
                f"End: {end.isoformat()}",
            ]
        )
        writer.writerow([])

        # 1. Summary
        writer.writerow(["SECTION: SUMMARY"])
        writer.writerow(
            ["Metric", f"This Week ({week})", f"Previous Week ({prev_week_str})", "Change"]
        )
        count_diff_str = f"+{count_diff}" if count_diff > 0 else str(count_diff)
        hours_diff_str = f"+{hours_diff:.2f}" if hours_diff > 0 else f"{hours_diff:.2f}"
        writer.writerow(["Meeting Count", curr_count, prev_count, count_diff_str])
        writer.writerow([
            "Total Duration (hours)",
            f"{curr_hours:.2f}",
            f"{prev_hours:.2f}",
            hours_diff_str,
        ])
        writer.writerow([])

        # 2. Top 5 longest meetings
        writer.writerow(["SECTION: TOP 5 LONGEST MEETINGS"])
        writer.writerow(
            ["Rank", "Title", "Start Time (UTC)", "Duration (hours)", "Participants Count"]
        )
        if not longest_meetings:
            writer.writerow(["-", "No meetings scheduled this week", "-", "-", "-"])
        else:
            for rank, m in enumerate(longest_meetings, 1):
                dur = (m.ends_at - m.starts_at).total_seconds() / 3600.0
                writer.writerow(
                    [
                        rank,
                        m.title,
                        m.starts_at.isoformat(),
                        f"{dur:.2f}",
                        len(m.participants),
                    ]
                )
        writer.writerow([])

        # 3. Organizer breakdown
        writer.writerow(["SECTION: ORGANIZER BREAKDOWN"])
        writer.writerow(["Name", "Email", "Meeting Count", "Total Duration (hours)"])
        if not organizer_stats:
            writer.writerow(["-", "-", "0", "0.00"])
        else:
            for stats in sorted(
                organizer_stats.values(), key=lambda x: x["count"], reverse=True
            ):
                writer.writerow(
                    [
                        stats["name"],
                        stats["email"],
                        stats["count"],
                        f"{stats['hours']:.2f}",
                    ]
                )

        return output.getvalue().encode("utf-8")

    if session is not None:
        return await _run(session)
    else:
        from app.config import settings
        from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
        from sqlalchemy.pool import NullPool

        local_engine = create_async_engine(settings.database_url, poolclass=NullPool)
        local_sessionmaker = async_sessionmaker(local_engine, expire_on_commit=False)
        try:
            async with local_sessionmaker() as s:
                return await _run(s)
        finally:
            await local_engine.dispose()



def build_weekly_report(week: str) -> bytes:
    """Query the meetings of one ISO week (e.g. "2026-W40") and return the CSV bytes."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if loop and loop.is_running():
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            return pool.submit(lambda: asyncio.run(generate_weekly_report(week))).result()
    else:
        return asyncio.run(generate_weekly_report(week))
