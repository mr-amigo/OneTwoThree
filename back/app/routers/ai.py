"""POST /api/ai/parse-agenda: the same parser behind the normal API auth (local Docker Compose)."""

from datetime import date

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, parse_agenda
from app.ai.agenda_lambda import MAX_TEXT_LENGTH, is_throttled
from app.ai.pricing import cost_usd
from app.auth import get_current_user
from app.config import settings
from app.models import User

router = APIRouter(prefix="/ai", tags=["ai"])


class ParseAgendaRequest(BaseModel):
    text: str
    today: date
    tz: str


@router.post("/parse-agenda")
def parse_agenda_endpoint(body: ParseAgendaRequest, user: User = Depends(get_current_user)):
    if len(body.text) > MAX_TEXT_LENGTH:
        return JSONResponse(status_code=413, content={"error": "Pasted text is too long"})
    try:
        agenda, usage = parse_agenda(body.text, body.today, body.tz)
    except AgendaParseError as exc:
        return JSONResponse(status_code=422, content={"error": str(exc)})
    except Exception as exc:
        if is_throttled(exc):
            return JSONResponse(status_code=429, content={"error": "The AI service is busy."})
        raise
    return {
        "agenda": agenda.model_dump(mode="json"),
        "model": settings.parser_model,
        "prompt_version": PROMPT_VERSION,
        "cost_usd": cost_usd(settings.parser_model, usage),
    }
