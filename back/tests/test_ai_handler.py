import base64
import json
from datetime import date
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.ai import agenda_lambda
from app.ai.agenda import PROMPT_VERSION
from app.ai.llm import BedrockProvider
from app.auth import Identity
from app.config import settings

GOOD = {"items": [{"topic": "Pricing", "owner": "Olena", "minutes": 15}], "language": "en"}


class FakeClient:
    def __init__(self, result=GOOD, error: Exception | None = None):
        self.calls = []
        self.messages = SimpleNamespace(create=self._create)
        self.result, self.error = result, error

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        block = SimpleNamespace(type="tool_use", id="t1", input=self.result)
        usage = SimpleNamespace(input_tokens=1000, output_tokens=200)
        return SimpleNamespace(content=[block], stop_reason="tool_use", usage=usage)


@pytest.fixture(autouse=True)
def signed_in(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(agenda_lambda, "verify_id_token", lambda token: Identity("sub-anna", "a@x.com", None))
    # The fake client answers like Claude on Bedrock, so log and price it as Opus 5.5.
    monkeypatch.setattr(settings, "parser_provider", "bedrock")
    monkeypatch.setattr(settings, "parser_model", "anthropic.claude-opus-5-5")


def event(body=None, token: str | None = "good") -> dict:
    payload = {"text": "Mon 10:00 pricing sync", "today": date(2026, 10, 26).isoformat(), "tz": "UTC"}
    if isinstance(body, dict):
        payload.update(body)
    return {
        "headers": {"Authorization": f"Bearer {token}"} if token else {},
        "body": body if isinstance(body, str) else json.dumps(payload),
    }


def call(ev, client=None):
    response = agenda_lambda.handler(ev, None, provider=BedrockProvider(client or FakeClient()))
    return response["statusCode"], json.loads(response["body"])


def test_success_returns_agenda_and_logs_one_json_line(caplog: pytest.LogCaptureFixture):
    caplog.set_level("INFO")
    status, body = call(event())
    assert status == 200 and body["agenda"]["items"][0]["owner"] == "Olena"
    assert body["prompt_version"] == PROMPT_VERSION and body["model"] == settings.parser_model
    line = json.loads(next(r.message for r in caplog.records if "agenda_parsed" in r.message))
    assert line["provider"] == "bedrock" and line["model"] == "anthropic.claude-opus-5-5"
    assert line["user"] == "sub-anna" and line["input_tokens"] == 1000 and line["output_tokens"] == 200
    assert line["cost_usd"] == pytest.approx(0.008) and "latency_ms" in line


def test_base64_body_is_accepted():
    ev = event()
    ev["body"], ev["isBase64Encoded"] = base64.b64encode(ev["body"].encode()).decode(), True
    assert call(ev)[0] == 200


def test_missing_or_invalid_token_is_401_and_costs_nothing(monkeypatch: pytest.MonkeyPatch):
    client = FakeClient()
    assert call(event(token=None), client)[0] == 401

    def reject(token):
        raise HTTPException(401, "Invalid token")

    monkeypatch.setattr(agenda_lambda, "verify_id_token", reject)
    assert call(event(), client)[0] == 401
    assert client.calls == []


def test_long_text_is_413_before_the_model_is_called():
    client = FakeClient()
    assert call(event({"text": "a" * (agenda_lambda.MAX_TEXT_LENGTH + 1)}), client)[0] == 413
    assert client.calls == []


@pytest.mark.parametrize("body", [{"text": " "}, {"today": "monday"}, {"tz": ""}, "not json", "[1]"])
def test_bad_requests_are_422(body):
    assert call(event(body))[0] == 422


def test_unknown_time_zone_and_no_agenda_are_422():
    assert call(event({"tz": "Mars/Base"}))[0] == 422
    assert call(event(), FakeClient({"items": [], "language": "en"}))[0] == 422


def test_throttling_is_429_and_outage_is_502():
    class RateLimitError(Exception):
        pass

    assert call(event(), FakeClient(error=RateLimitError()))[0] == 429
    assert call(event(), FakeClient(error=RuntimeError("down")))[0] == 502


def test_failed_parse_is_logged_with_its_cost(caplog: pytest.LogCaptureFixture):
    caplog.set_level("INFO")
    status, _ = call(event(), FakeClient({"items": [], "language": "en"}))
    assert status == 422
    line = json.loads(next(r.message for r in caplog.records if "agenda_not_parsed" in r.message))
    assert line["error"] == "no agenda found in the text" and line["attempts"] == 1
    assert line["cost_usd"] == pytest.approx(0.008)
    assert "Mon 10:00" not in json.dumps(line)  # the pasted text is never logged
