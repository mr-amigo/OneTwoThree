"""AWS Lambda entry point for the agenda parser Function URL. Runs outside the VPC, no database."""

import base64
import json
import logging
import time
from datetime import date
from typing import Any

from fastapi import HTTPException

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, parse_agenda
from app.ai.llm import Provider
from app.ai.pricing import cost_usd
from app.auth import verify_id_token
from app.config import settings

MAX_TEXT_LENGTH = 10_000

logger = logging.getLogger("agenda_parser")
logger.setLevel(logging.INFO)


def _response(status: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(payload, ensure_ascii=False),
    }


def is_throttled(exc: Exception) -> bool:
    """True for Bedrock/Anthropic rate limiting (HTTP 429 or ThrottlingException)."""
    if getattr(exc, "status_code", None) == 429:
        return True
    response = getattr(exc, "response", None)
    if isinstance(response, dict) and response.get("Error", {}).get("Code") == "ThrottlingException":
        return True
    return type(exc).__name__ == "RateLimitError"


def _read_body(event: dict[str, Any]) -> Any:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw)


def handler(event: dict[str, Any], context: Any, provider: Provider | None = None) -> dict[str, Any]:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization", "")
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    if not token:
        return _response(401, {"error": "Sign in required"})
    try:
        identity = verify_id_token(token)
    except HTTPException as exc:
        return _response(401, {"error": str(exc.detail)})
    except OSError:  # the pool's signing keys could not be downloaded
        return _response(503, {"error": "Sign-in check is unavailable. Please try again."})

    try:
        body = _read_body(event)
    except (ValueError, TypeError):
        return _response(422, {"error": "Request body must be valid JSON"})
    if not isinstance(body, dict):
        return _response(422, {"error": "Request body must be a JSON object"})

    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        return _response(422, {"error": "Field 'text' is required"})
    if len(text) > MAX_TEXT_LENGTH:
        return _response(413, {"error": f"Pasted text is too long (maximum is {MAX_TEXT_LENGTH} characters)"})
    try:
        today = date.fromisoformat(str(body.get("today", "")))
    except ValueError:
        return _response(422, {"error": "Field 'today' must be a date (YYYY-MM-DD)"})
    tz = body.get("tz")
    if not isinstance(tz, str) or not tz:
        return _response(422, {"error": "Field 'tz' is required (IANA time zone name)"})

    started = time.monotonic()

    def log(event: str, usage: dict[str, Any] | None = None, **extra: Any) -> None:
        """One JSON line per parse, failed ones included: every model call costs money."""
        line: dict[str, Any] = {
            "event": event,
            "user": identity.sub,
            "provider": settings.parser_provider,
            "model": settings.parser_model,
            "prompt_version": PROMPT_VERSION,
        }
        if usage:
            line |= {
                "input_tokens": usage["input_tokens"],
                "output_tokens": usage["output_tokens"],
                "attempts": usage["attempts"],
                "retry_reasons": usage["retry_reasons"],
            }
        line["latency_ms"] = int((time.monotonic() - started) * 1000)
        if usage:
            line["cost_usd"] = cost_usd(settings.parser_model, usage)
        logger.log(logging.WARNING if event != "agenda_parsed" else logging.INFO, json.dumps(line | extra))

    try:
        agenda, usage = parse_agenda(text, today, tz, provider=provider)
    except AgendaParseError as exc:
        log("agenda_not_parsed", exc.usage, error=str(exc))
        return _response(422, {"error": str(exc)})
    except Exception as exc:
        if is_throttled(exc):
            log("agenda_throttled", error=type(exc).__name__)
            return _response(429, {"error": "The AI service is busy. Please try again."})
        log("agenda_parse_failed", error=type(exc).__name__)
        return _response(502, {"error": "The AI service is unavailable. Type the agenda by hand."})

    log("agenda_parsed", usage)
    return _response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": settings.parser_model,
            "prompt_version": PROMPT_VERSION,
        },
    )
