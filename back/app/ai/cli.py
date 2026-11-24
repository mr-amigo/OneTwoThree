"""Try the parser from a laptop: `make llm-hello` and `make parse TEXT="..."`.

The provider and model come from PARSER_PROVIDER / PARSER_MODEL (.env, or `make ... PARSER_PROVIDER=bedrock`).
"""

import json
import sys
import time
from datetime import date

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, llm_hello, parse_agenda
from app.ai.pricing import cost_usd
from app.config import settings


def parse(text: str, tz: str = "Europe/Kyiv") -> None:
    started = time.monotonic()
    agenda, usage = parse_agenda(text, date.today(), tz)
    latency_ms = int((time.monotonic() - started) * 1000)
    print(json.dumps(agenda.model_dump(mode="json"), ensure_ascii=False, indent=2))
    cost = cost_usd(settings.parser_model, usage)
    print(
        f"provider={settings.parser_provider} model={settings.parser_model} prompt={PROMPT_VERSION} "
        f"usage={usage} latency_ms={latency_ms} cost_usd={cost}"
    )


def main(argv: list[str]) -> int:
    command, *args = argv or ["hello"]
    try:
        if command == "hello":
            llm_hello()
        elif command == "parse" and args:
            parse(" ".join(args))
        else:
            print("usage: python -m app.ai.cli hello | parse TEXT", file=sys.stderr)
            return 2
    except AgendaParseError as exc:
        print(f"Could not parse: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # access denied, throttling, network: show the provider's own message
        where = f"{settings.parser_provider} / {settings.parser_model}"
        print(f"{where}: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
