import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    Column,
    DateTime,
    ForeignKey,
    JSON,
    String,
    Table,
    Text,
    Uuid,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


meeting_participants = Table(
    "meeting_participants",
    Base.metadata,
    Column("meeting_id", Uuid, ForeignKey("meetings.id", ondelete="CASCADE"), primary_key=True),
    Column(
        "participant_id",
        Uuid,
        ForeignKey("participants.id", ondelete="CASCADE"),
        primary_key=True,
    ),
)


class User(Base):
    """An account in the Cognito user pool, created on its first authenticated request."""

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    # Cognito's stable user id (the token's "sub" claim).
    cognito_sub: Mapped[str] = mapped_column(String(64), unique=True)
    # Not unique: a password account and a Google account can share an email.
    email: Mapped[str] = mapped_column(String(255), index=True)
    name: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Participant(Base):
    __tablename__ = "participants"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(100))
    email: Mapped[str] = mapped_column(String(255), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    meetings: Mapped[list[Meeting]] = relationship(
        secondary=meeting_participants, back_populates="participants", passive_deletes=True
    )


class Meeting(Base):
    __tablename__ = "meetings"
    __table_args__ = (CheckConstraint("ends_at > starts_at", name="ck_meetings_ends_after_starts"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text, default="", server_default="")
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    place: Mapped[str] = mapped_column(String(200))
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    ai_suggestion: Mapped[dict | None] = mapped_column(JSON, nullable=True, default=None)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    participants: Mapped[list[Participant]] = relationship(
        secondary=meeting_participants,
        back_populates="meetings",
        order_by=Participant.name,
        passive_deletes=True,
    )
