from fastapi import APIRouter, Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.auth import get_current_user
from app.config import settings
from app.db import SessionDep
from app.routers import me, meetings, participants

app = FastAPI(
    title="Meetings API",
    docs_url="/api/docs",
    redoc_url=None,
    openapi_url="/api/openapi.json",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

api = APIRouter(prefix="/api")


@api.get("/health", tags=["health"])
async def health(session: SessionDep) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ok"}


@app.post("/events")
async def handle_events(request: Request):
    event = await request.json()
    from app.reports.lambda_handler import handler

    return handler(event, None)


# Everything but /api/health needs a signed-in user; meetings are scoped to their owner.
api.include_router(me.router)
api.include_router(meetings.router)
api.include_router(participants.router, dependencies=[Depends(get_current_user)])
app.include_router(api)

