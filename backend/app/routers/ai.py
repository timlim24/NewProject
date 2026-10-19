"""API routes for AI services (local and proxy parsing)."""

from datetime import date
import logging
import time

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda
from app.auth import CurrentUser
from app.config import settings

logger = logging.getLogger("ai_router")
router = APIRouter(prefix="/ai", tags=["ai"])


class ParseRequest(BaseModel):
    text: str = Field(max_length=10000)
    today: date = Field(default_factory=date.today)
    tz: str = "Europe/Kyiv"
    model: str | None = None


class ParseResponse(BaseModel):
    agenda: dict
    model: str
    prompt_version: str


@router.post("/parse", response_model=ParseResponse)
async def parse_agenda_endpoint(payload: ParseRequest, user: CurrentUser):
    started = time.monotonic()
    active_model = payload.model or settings.parser_model

    try:
        agenda, usage = parse_agenda(
            payload.text, today=payload.today, tz=payload.tz, model=active_model
        )
    except AgendaParseError as e:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(e)
        ) from e
    except Exception as e:
        err_msg = str(e)
        if "ThrottlingException" in err_msg or "429" in err_msg:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Bedrock is busy. Please try again shortly.",
            ) from e
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Parsing error: {err_msg}",
        ) from e

    latency_ms = int((time.monotonic() - started) * 1000)
    logger.info(
        '{"event": "agenda_parsed", "user": "%s", "model": "%s", "prompt_version": "%s", '
        '"input_tokens": %d, "output_tokens": %d, "latency_ms": %d, "cost_usd": %f}',
        user.cognito_sub,
        active_model,
        PROMPT_VERSION,
        usage.get("input_tokens", 0),
        usage.get("output_tokens", 0),
        latency_ms,
        cost_usd(active_model, usage),
    )

    return ParseResponse(
        agenda=agenda.model_dump(mode="json"),
        model=active_model,
        prompt_version=PROMPT_VERSION,
    )
