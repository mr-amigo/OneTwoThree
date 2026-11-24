"""One interface in front of the parser's LLM providers.

- `bedrock`: Claude through the Anthropic Messages API on Bedrock (bedrock-mantle), as in the lab.
- `bedrock-converse`: any Bedrock model through the provider-neutral Converse API (bedrock-runtime).
- `openai`: the OpenAI Responses API.

The parser asks for exactly one tool call and, if the arguments are invalid, shows the model its error once.
Each provider keeps that conversation in its own wire format; the parser only sees `Reply`.
"""

import json
from dataclasses import dataclass
from typing import Any, Protocol

from app.config import settings

BEDROCK_REGION = "us-east-1"


@dataclass
class Reply:
    tool_input: dict[str, Any] | None  # None: the model did not call the tool
    stop_reason: str
    input_tokens: int
    output_tokens: int
    parse_error: str | None = None  # the arguments were not valid JSON


class Conversation(Protocol):
    def ask(self) -> Reply: ...

    def add_tool_error(self, error: str) -> None: ...


class Provider(Protocol):
    name: str

    def conversation(self, system: str, user: str, tool: dict[str, Any]) -> Conversation: ...

    def hello(self, question: str) -> tuple[str, Reply]: ...


# --- Claude on Amazon Bedrock (Anthropic Messages API, bedrock-mantle) -------------------------------------


class BedrockConversation:
    def __init__(self, client: Any, system: str, user: str, tool: dict[str, Any]) -> None:
        self.client, self.system, self.tool = client, system, tool
        self.messages: list[dict[str, Any]] = [{"role": "user", "content": user}]
        self.last: Any = None

    def ask(self) -> Reply:
        # Claude Opus 5.5 takes no forced tool choice, so the system prompt asks for the tool.
        msg = self.client.messages.create(
            model=settings.parser_model,
            max_tokens=4096,
            output_config={"effort": "low"},
            system=self.system,
            tools=[self.tool],
            messages=self.messages,
        )
        self.last = msg
        call = next((b for b in msg.content if b.type == "tool_use"), None)
        return Reply(
            tool_input=call.input if call else None,
            stop_reason=msg.stop_reason,
            input_tokens=msg.usage.input_tokens,
            output_tokens=msg.usage.output_tokens,
        )

    def add_tool_error(self, error: str) -> None:
        call = next(b for b in self.last.content if b.type == "tool_use")
        self.messages = [
            *self.messages,
            {"role": "assistant", "content": self.last.content},
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": call.id, "content": error, "is_error": True}
                ],
            },
        ]


class BedrockProvider:
    name = "bedrock"

    def __init__(self, client: Any = None) -> None:
        if client is None:
            from anthropic import AnthropicBedrockMantle

            client = AnthropicBedrockMantle(aws_region=BEDROCK_REGION)
        self.client = client

    def conversation(self, system: str, user: str, tool: dict[str, Any]) -> BedrockConversation:
        return BedrockConversation(self.client, system, user, tool)

    def hello(self, question: str) -> tuple[str, Reply]:
        msg = self.client.messages.create(
            model=settings.parser_model,
            max_tokens=1024,
            output_config={"effort": "low"},
            messages=[{"role": "user", "content": question}],
        )
        text = next((b.text for b in msg.content if b.type == "text"), "")
        return text, Reply(None, msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)


# --- Amazon Bedrock Converse API (bedrock-runtime) -------------------------------------------------------
# Provider-neutral AWS request shape: the same code calls Claude through an inference profile
# (us.anthropic.claude-haiku-5-5, global.…), Amazon Nova, Llama or Mistral. Only modelId changes.


class ConverseConversation:
    def __init__(self, client: Any, system: str, user: str, tool: dict[str, Any]) -> None:
        self.client, self.system = client, system
        spec = {
            "name": tool["name"],
            "description": tool["description"],
            "inputSchema": {"json": tool["input_schema"]},
        }
        self.tool_config = {"tools": [{"toolSpec": spec}]}
        self.messages: list[dict[str, Any]] = [{"role": "user", "content": [{"text": user}]}]
        self.last: dict[str, Any] = {}

    def ask(self) -> Reply:
        resp = self.client.converse(
            modelId=settings.parser_model,
            system=[{"text": self.system}],
            messages=self.messages,
            toolConfig=self.tool_config,
            inferenceConfig={"maxTokens": 4096},
        )
        self.last = resp["output"]["message"]
        use = next((b["toolUse"] for b in self.last["content"] if "toolUse" in b), None)
        return Reply(
            tool_input=use["input"] if use else None,
            stop_reason=resp["stopReason"],
            input_tokens=resp["usage"]["inputTokens"],
            output_tokens=resp["usage"]["outputTokens"],
        )

    def add_tool_error(self, error: str) -> None:
        use = next(b["toolUse"] for b in self.last["content"] if "toolUse" in b)
        result = {"toolUseId": use["toolUseId"], "content": [{"text": error}], "status": "error"}
        self.messages = [*self.messages, self.last, {"role": "user", "content": [{"toolResult": result}]}]


class ConverseProvider:
    name = "bedrock-converse"

    def __init__(self, client: Any = None) -> None:
        if client is None:
            import boto3

            client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
        self.client = client

    def conversation(self, system: str, user: str, tool: dict[str, Any]) -> ConverseConversation:
        return ConverseConversation(self.client, system, user, tool)

    def hello(self, question: str) -> tuple[str, Reply]:
        resp = self.client.converse(
            modelId=settings.parser_model,
            messages=[{"role": "user", "content": [{"text": question}]}],
            inferenceConfig={"maxTokens": 200},
        )
        text = next((b["text"] for b in resp["output"]["message"]["content"] if "text" in b), "")
        usage = resp["usage"]
        return text, Reply(None, resp["stopReason"], usage["inputTokens"], usage["outputTokens"])


# --- OpenAI API (Responses API, function calling) ---------------------------------------------------------
# The Responses API, not Chat Completions: gpt-5.x accepts function tools together with reasoning only here.


def _reasoning() -> dict[str, Any]:
    """reasoning.effort for reasoning models; an empty OPENAI_REASONING_EFFORT leaves it out."""
    effort = settings.openai_reasoning_effort
    return {"reasoning": {"effort": effort}, "include": ["reasoning.encrypted_content"]} if effort else {}


def _stop_reason(resp: Any, called: bool) -> str:
    if called:
        return "tool_use"
    if any(c.type == "refusal" for item in resp.output if item.type == "message" for c in item.content):
        return "refusal"
    if resp.status == "incomplete" and resp.incomplete_details:
        return str(resp.incomplete_details.reason)  # e.g. max_output_tokens
    return str(resp.status)


class OpenAIConversation:
    def __init__(self, client: Any, system: str, user: str, tool: dict[str, Any]) -> None:
        self.client, self.system = client, system
        self.tool_name = tool["name"]
        self.tools = [
            {
                "type": "function",
                "name": tool["name"],
                "description": tool["description"],
                "parameters": tool["input_schema"],
                "strict": False,  # strict mode needs every field required; Pydantic validates instead
            }
        ]
        self.input: list[Any] = [{"role": "user", "content": user}]
        self.last_output: list[Any] = []
        self.last_call: Any = None

    def ask(self) -> Reply:
        # OpenAI can force the tool, so the model cannot answer with prose instead of an agenda.
        # store=False: the pasted text is not kept on OpenAI's side for later retrieval.
        resp = self.client.responses.create(
            model=settings.parser_model,
            instructions=self.system,
            input=self.input,
            tools=self.tools,
            tool_choice={"type": "function", "name": self.tool_name},
            parallel_tool_calls=False,
            max_output_tokens=4096,
            store=False,
            **_reasoning(),
        )
        call = next((o for o in resp.output if o.type == "function_call" and o.name == self.tool_name), None)
        self.last_output, self.last_call = list(resp.output), call
        reply = Reply(
            tool_input=None,
            stop_reason=_stop_reason(resp, call is not None),
            input_tokens=resp.usage.input_tokens,
            output_tokens=resp.usage.output_tokens,  # includes reasoning tokens, billed as output
        )
        if call is not None:
            try:
                reply.tool_input = json.loads(call.arguments)
            except json.JSONDecodeError as exc:
                reply.tool_input = {}
                reply.parse_error = f"arguments are not valid JSON: {exc}"
        return reply

    def add_tool_error(self, error: str) -> None:
        # Send the model's own output back (with its encrypted reasoning), then the error for its call.
        echoed = [
            o.model_dump(exclude_none=True) if hasattr(o, "model_dump") else o for o in self.last_output
        ]
        result = {
            "type": "function_call_output",
            "call_id": self.last_call.call_id,
            "output": f"Error: {error}",
        }
        self.input = [*self.input, *echoed, result]


class OpenAIProvider:
    name = "openai"

    def __init__(self, client: Any = None) -> None:
        if client is None:
            from openai import OpenAI

            client = OpenAI(api_key=settings.openai_api_key or None, max_retries=2, timeout=25)
        self.client = client

    def conversation(self, system: str, user: str, tool: dict[str, Any]) -> OpenAIConversation:
        return OpenAIConversation(self.client, system, user, tool)

    def hello(self, question: str) -> tuple[str, Reply]:
        resp = self.client.responses.create(
            model=settings.parser_model, input=question, max_output_tokens=1024, store=False, **_reasoning()
        )
        reply = Reply(None, _stop_reason(resp, False), resp.usage.input_tokens, resp.usage.output_tokens)
        return resp.output_text, reply


PROVIDERS = {"openai": OpenAIProvider, "bedrock": BedrockProvider, "bedrock-converse": ConverseProvider}
_provider: Provider | None = None


def get_provider() -> Provider:
    """The provider from PARSER_PROVIDER, created on first use so tests can pass a fake instead."""
    global _provider
    if _provider is None:
        factory = PROVIDERS.get(settings.parser_provider)
        if factory is None:
            raise ValueError(
                f"Unknown PARSER_PROVIDER {settings.parser_provider!r} (use one of {sorted(PROVIDERS)})"
            )
        _provider = factory()
    return _provider
