import uuid

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth import CurrentUser
from app.db import SessionDep
from app.models import Meeting, Participant, User
from app.schemas import MeetingCreate, MeetingRead

router = APIRouter(prefix="/meetings", tags=["meetings"])


async def _get_meeting(session: AsyncSession, meeting_id: uuid.UUID, user: User) -> Meeting:
    """The user's meeting; someone else's meeting is reported as missing, not forbidden."""
    meeting = await session.scalar(
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.id == meeting_id, Meeting.owner_id == user.id)
    )
    if meeting is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Meeting not found")
    return meeting


@router.get("", response_model=list[MeetingRead])
async def list_meetings(session: SessionDep, user: CurrentUser) -> list[Meeting]:
    result = await session.scalars(
        select(Meeting)
        .options(selectinload(Meeting.participants))
        .where(Meeting.owner_id == user.id)
        .order_by(Meeting.starts_at, Meeting.created_at)
    )
    return list(result)


@router.get("/{meeting_id}", response_model=MeetingRead)
async def get_meeting(meeting_id: uuid.UUID, session: SessionDep, user: CurrentUser) -> Meeting:
    return await _get_meeting(session, meeting_id, user)


async def _get_participants(
    session: AsyncSession, participant_ids: list[uuid.UUID]
) -> list[Participant]:
    if not participant_ids:
        return []
    found = await session.scalars(select(Participant).where(Participant.id.in_(participant_ids)))
    participants = list(found)
    unknown = set(participant_ids) - {p.id for p in participants}
    if unknown:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            f"Unknown participant ids: {', '.join(sorted(str(u) for u in unknown))}",
        )
    return participants


@router.post("", response_model=MeetingRead, status_code=status.HTTP_201_CREATED)
async def create_meeting(payload: MeetingCreate, session: SessionDep, user: CurrentUser) -> Meeting:
    participants = await _get_participants(session, payload.participant_ids)
    meeting = Meeting(
        title=payload.title,
        description=payload.description,
        starts_at=payload.starts_at,
        ends_at=payload.ends_at,
        place=payload.place,
        participants=participants,
        owner_id=user.id,
        ai_suggestion=payload.ai_suggestion,
    )
    session.add(meeting)
    await session.commit()
    return await _get_meeting(session, meeting.id, user)


@router.put("/{meeting_id}", response_model=MeetingRead)
async def update_meeting(
    meeting_id: uuid.UUID, payload: MeetingCreate, session: SessionDep, user: CurrentUser
) -> Meeting:
    meeting = await _get_meeting(session, meeting_id, user)
    meeting.participants = await _get_participants(session, payload.participant_ids)
    meeting.title = payload.title
    meeting.description = payload.description
    meeting.starts_at = payload.starts_at
    meeting.ends_at = payload.ends_at
    meeting.place = payload.place
    if payload.ai_suggestion is not None:
        meeting.ai_suggestion = payload.ai_suggestion
    await session.commit()
    session.expunge(meeting)
    return await _get_meeting(session, meeting_id, user)


@router.delete("/{meeting_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_meeting(meeting_id: uuid.UUID, session: SessionDep, user: CurrentUser) -> Response:
    meeting = await session.get(Meeting, meeting_id)
    if meeting is None or meeting.owner_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Meeting not found")
    await session.delete(meeting)
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
