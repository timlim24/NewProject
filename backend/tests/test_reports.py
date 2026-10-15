from datetime import datetime, timezone
import pytest

from app.models import Meeting, Participant, User
from app.reports.lambda_handler import detect_trigger, extract_week
from app.reports.weekly import generate_weekly_report, parse_iso_week


def test_parse_iso_week():
    start, end = parse_iso_week("2026-W41")
    assert start == datetime(2026, 10, 5, 0, 0, 0, tzinfo=timezone.utc)
    assert end == datetime(2026, 10, 12, 0, 0, 0, tzinfo=timezone.utc)

    # Invalid weeks
    with pytest.raises(ValueError):
        parse_iso_week("invalid")
    with pytest.raises(ValueError):
        parse_iso_week("2026-W54")


def test_detect_trigger():
    # Schedule direct
    assert detect_trigger({"source": "schedule"}) == "schedule"
    # Schedule via SQS
    assert (
        detect_trigger({"Records": [{"body": '{"week": null, "source": "schedule"}'}]})
        == "schedule"
    )
    # Manual via SQS
    assert (
        detect_trigger({"Records": [{"body": '{"week": "2026-W41", "source": "manual"}'}]})
        == "sqs"
    )
    # Direct
    assert detect_trigger({"week": "2026-W41"}) == "direct"


def test_extract_week():
    # Explicit week in direct event
    assert extract_week({"week": "2026-W40"}) == "2026-W40"
    # Explicit week in SQS event
    assert (
        extract_week({"Records": [{"body": '{"week": "2026-W39"}'}]})
        == "2026-W39"
    )
    # Missing week defaults to last ISO week
    week = extract_week({})
    assert "-W" in week


@pytest.mark.asyncio
async def test_generate_weekly_report(session):
    # Create an organizer user
    user = User(
        cognito_sub="user-test-sub",
        email="organizer@example.com",
        name="Test Organizer",
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)

    # Create participant
    participant = Participant(name="Bob", email="bob@example.com")
    session.add(participant)
    await session.commit()
    await session.refresh(participant)

    # Create a meeting in week 2026-W41 (starts 2026-10-06 10:00:00)
    m1 = Meeting(
        title="Weekly Sync",
        description="Discuss progress",
        starts_at=datetime(2026, 10, 6, 10, 0, 0, tzinfo=timezone.utc),
        ends_at=datetime(2026, 10, 6, 11, 30, 0, tzinfo=timezone.utc),
        place="Room 101",
        owner_id=user.id,
        participants=[participant],
    )
    session.add(m1)
    await session.commit()

    # Generate CSV report for week 2026-W41
    csv_bytes = await generate_weekly_report("2026-W41", session=session)
    csv_text = csv_bytes.decode("utf-8")

    assert "Weekly Meetings Report" in csv_text
    assert "Week: 2026-W41" in csv_text
    assert "Meeting Count,1,0,+1" in csv_text
    assert "Weekly Sync" in csv_text
    assert "Test Organizer" in csv_text
    assert "organizer@example.com" in csv_text
