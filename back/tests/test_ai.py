import json
from datetime import date
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, parse_agenda
from app.ai.llm import BedrockProvider, ConverseProvider, OpenAIProvider
from app.ai.pricing import cost_usd
from app.ai.schemas import AgendaItem, ParsedAgenda
from app.config import settings


class FakeMessages:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def create(self, **kwargs):
        self.calls.append(kwargs)
        return self.responses.pop(0)


class FakeClient:
    def __init__(self, responses):
        self.messages = FakeMessages(responses)


def tool_msg(payload, call_id="tu_1", stop_reason="tool_use"):
    block = SimpleNamespace(type="tool_use", id=call_id, input=payload)
    usage = SimpleNamespace(input_tokens=100, output_tokens=40)
    return SimpleNamespace(content=[block], stop_reason=stop_reason, usage=usage)


VALID = {"items": [{"topic": "Pricing", "owner": "Olena", "minutes": 15}], "language": "en"}
BAD = {"items": [{"topic": ""}], "language": "en"}


def test_schema_limits():
    with pytest.raises(ValidationError):
        AgendaItem(topic="", minutes=15)
    with pytest.raises(ValidationError):
        AgendaItem(topic="x", minutes=481)
    with pytest.raises(ValidationError):
        ParsedAgenda(items=[], language="en", duration_minutes=601)
    with pytest.raises(ValidationError):
        ParsedAgenda(items=[], language="en", starts_at="2026-11-02T10:00:00")  # no offset
    ok = ParsedAgenda(items=[], language="en", starts_at="2026-11-02T10:00:00+02:00")
    assert ok.starts_at == "2026-11-02T10:00:00+02:00"


def test_cost_usd_and_unknown_model():
    usage = {"input_tokens": 1000, "output_tokens": 1000}
    assert cost_usd("anthropic.claude-opus-5-5", usage) == 0.024
    assert cost_usd("anthropic.claude-haiku-5-5", usage) == 0.0006
    assert cost_usd("unknown-model", usage) is None


def test_parse_success_and_usage_sum():
    client = FakeClient([tool_msg(VALID)])
    agenda, usage = parse_agenda(
        "Pricing sync", date(2026, 10, 29), "Europe/Kyiv", provider=BedrockProvider(client)
    )
    assert agenda.items[0].owner == "Olena"
    assert {k: usage[k] for k in ("input_tokens", "output_tokens")} == {
        "input_tokens": 100,
        "output_tokens": 40,
    }
    prompt = client.messages.calls[0]["messages"][0]["content"]
    assert "Today is Thursday 2026-10-29, time zone Europe/Kyiv (UTC+02:00)." in prompt
    assert "<pasted_text>" in prompt


def test_parse_retries_once_with_tool_error():
    client = FakeClient([tool_msg(BAD, "tu_bad"), tool_msg(VALID, "tu_ok")])
    agenda, usage = parse_agenda("text", date(2026, 10, 29), "UTC", provider=BedrockProvider(client))
    assert agenda.items[0].topic == "Pricing"
    assert {k: usage[k] for k in ("input_tokens", "output_tokens")} == {
        "input_tokens": 200,
        "output_tokens": 80,
    }
    assert usage["attempts"] == 2 and usage["retry_reasons"] == ["items.0.topic:string_too_short"]
    retry_messages = client.messages.calls[1]["messages"]
    result_block = retry_messages[-1]["content"][0]
    assert result_block["is_error"] is True
    assert result_block["tool_use_id"] == "tu_bad"


def test_parse_fails_after_two_invalid_results():
    client = FakeClient([tool_msg(BAD), tool_msg(BAD)])
    with pytest.raises(AgendaParseError, match="invalid agenda twice"):
        parse_agenda("text", date(2026, 10, 29), "UTC", provider=BedrockProvider(client))


def test_parse_refusal_raises_without_retry():
    refusal = SimpleNamespace(
        content=[],
        stop_reason="refusal",
        usage=SimpleNamespace(input_tokens=5, output_tokens=0),
    )
    client = FakeClient([refusal])
    with pytest.raises(AgendaParseError, match="stop_reason=refusal"):
        parse_agenda("text", date(2026, 10, 29), "UTC", provider=BedrockProvider(client))
    assert len(client.messages.calls) == 1


def test_empty_text_makes_no_model_call():
    client = FakeClient([])
    with pytest.raises(AgendaParseError):
        parse_agenda("   ", date(2026, 10, 29), "UTC", provider=BedrockProvider(client))
    assert client.messages.calls == []


def test_prompt_version_is_pinned():
    assert PROMPT_VERSION == "agenda-v1"


def test_text_without_an_agenda_is_an_error():
    client = FakeClient([tool_msg({"items": [], "language": "en"})])
    with pytest.raises(AgendaParseError, match="no agenda found"):
        parse_agenda("milk, eggs", date(2026, 10, 29), "UTC", provider=BedrockProvider(client))


def test_unknown_time_zone_makes_no_model_call():
    client = FakeClient([])
    with pytest.raises(AgendaParseError, match="Unknown time zone"):
        parse_agenda("x", date(2026, 10, 29), "Mars/Base", provider=BedrockProvider(client))
    assert client.messages.calls == []


# --- OpenAI provider (Responses API) ---------------------------------------------------------------------


class FakeResponses:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def create(self, **kwargs):
        self.calls.append({**kwargs, "input": list(kwargs.get("input", []))})
        return self.responses.pop(0)


class FakeOpenAI:
    def __init__(self, responses):
        self.responses = FakeResponses(responses)


class Item(SimpleNamespace):
    def model_dump(self, exclude_none=False):
        return {k: v for k, v in vars(self).items() if not (exclude_none and v is None)}


def openai_resp(arguments, call_id="call_1", refusal=False, status="completed"):
    output = [Item(type="reasoning", id="rs_1", encrypted_content="enc")]
    if arguments is not None:
        args = arguments if isinstance(arguments, str) else json.dumps(arguments)
        output.append(Item(type="function_call", call_id=call_id, name="record_agenda", arguments=args))
    if refusal:
        output.append(Item(type="message", content=[SimpleNamespace(type="refusal", refusal="no")]))
    usage = SimpleNamespace(input_tokens=300, output_tokens=60)
    return SimpleNamespace(output=output, usage=usage, status=status, incomplete_details=None)


def test_openai_forces_the_tool_and_returns_usage():
    client = FakeOpenAI([openai_resp(VALID)])
    provider = OpenAIProvider(client)
    agenda, usage = parse_agenda("Pricing sync", date(2026, 10, 29), "Europe/Kyiv", provider=provider)
    assert agenda.items[0].owner == "Olena"
    assert {k: usage[k] for k in ("input_tokens", "output_tokens")} == {
        "input_tokens": 300,
        "output_tokens": 60,
    }
    call = client.responses.calls[0]
    assert call["tool_choice"] == {"type": "function", "name": "record_agenda"}
    assert call["tools"][0]["parameters"] == ParsedAgenda.model_json_schema()
    assert call["store"] is False and call["reasoning"] == {"effort": "low"}
    assert "record_agenda" in call["instructions"] and "<pasted_text>" in call["input"][0]["content"]


def test_openai_retries_once_after_invalid_json_or_schema():
    client = FakeOpenAI([openai_resp("{not json", "call_bad"), openai_resp(VALID, "call_ok")])
    agenda, usage = parse_agenda("text", date(2026, 10, 29), "UTC", provider=OpenAIProvider(client))
    assert agenda.items[0].topic == "Pricing"
    assert {k: usage[k] for k in ("input_tokens", "output_tokens")} == {
        "input_tokens": 600,
        "output_tokens": 120,
    }
    retry = client.responses.calls[1]["input"]
    assert [i["type"] for i in retry[1:]] == ["reasoning", "function_call", "function_call_output"]
    assert retry[-1]["call_id"] == "call_bad" and retry[-1]["output"].startswith("Error:")
    assert usage["retry_reasons"] == ["invalid_json"]


def test_openai_invalid_twice_and_refusal():
    client = FakeOpenAI([openai_resp(BAD), openai_resp(BAD)])
    with pytest.raises(AgendaParseError, match="invalid agenda twice"):
        parse_agenda("text", date(2026, 10, 29), "UTC", provider=OpenAIProvider(client))
    client = FakeOpenAI([openai_resp(None, refusal=True)])
    with pytest.raises(AgendaParseError, match="stop_reason=refusal"):
        parse_agenda("text", date(2026, 10, 29), "UTC", provider=OpenAIProvider(client))


def test_openai_reasoning_effort_is_optional(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "openai_reasoning_effort", "")
    client = FakeOpenAI([openai_resp(VALID)])
    parse_agenda("text", date(2026, 10, 29), "UTC", provider=OpenAIProvider(client))
    assert "reasoning" not in client.responses.calls[0] and "include" not in client.responses.calls[0]


# --- Bedrock Converse provider --------------------------------------------------------------------------


class FakeConverse:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def converse(self, **kwargs):
        self.calls.append({**kwargs, "messages": list(kwargs["messages"])})
        return self.responses.pop(0)


def converse_resp(payload, use_id="tu_1"):
    content = [{"toolUse": {"toolUseId": use_id, "name": "record_agenda", "input": payload}}]
    return {
        "output": {"message": {"role": "assistant", "content": content}},
        "stopReason": "tool_use",
        "usage": {"inputTokens": 200, "outputTokens": 50},
    }


def test_converse_tool_spec_and_retry():
    client = FakeConverse([converse_resp(BAD, "tu_bad"), converse_resp(VALID, "tu_ok")])
    agenda, usage = parse_agenda("text", date(2026, 10, 29), "UTC", provider=ConverseProvider(client))
    assert agenda.items[0].topic == "Pricing"
    assert usage["input_tokens"] == 400 and usage["attempts"] == 2
    first = client.calls[0]
    spec = first["toolConfig"]["tools"][0]["toolSpec"]
    assert spec["name"] == "record_agenda" and spec["inputSchema"]["json"] == ParsedAgenda.model_json_schema()
    assert first["system"][0]["text"].startswith("You turn text")
    result = client.calls[1]["messages"][-1]["content"][0]["toolResult"]
    assert result["toolUseId"] == "tu_bad" and result["status"] == "error"


def test_provider_selection(monkeypatch: pytest.MonkeyPatch):
    from app.ai import llm

    monkeypatch.setattr(llm, "_provider", None)
    monkeypatch.setattr(settings, "parser_provider", "nope")
    with pytest.raises(ValueError, match="Unknown PARSER_PROVIDER"):
        llm.get_provider()


def test_prices_for_openai_and_bedrock_inference_profiles():
    million = {"input_tokens": 1_000_000, "output_tokens": 1_000_000}
    assert cost_usd("gpt-5.4-mini", million) == 5.25
    assert cost_usd("gpt-5.4-nano", million) == 1.45
    assert cost_usd("global.anthropic.claude-haiku-5-5", million) == 0.6
    assert cost_usd("us.anthropic.claude-haiku-5-5", million) == 0.66  # regional profile: +10%
