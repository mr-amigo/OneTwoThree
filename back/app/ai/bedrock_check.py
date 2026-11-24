"""Is this AWS account ready to run the parser on Bedrock? `make bedrock-check`.

For each Claude model: model access (authorization, Marketplace agreement, region), the inference
quotas applied to this account next to AWS's defaults, and one tiny real call through both Bedrock APIs
(Anthropic Messages on bedrock-mantle, Converse on bedrock-runtime). Ends with READY or BLOCKED and
the command that switches the parser over.
"""

import sys
from typing import Any

import boto3

REGION = "us-east-1"
# (model ID for availability and the Messages API, inference profile ID for Converse)
MODELS = [
    ("anthropic.claude-opus-5-5", "global.anthropic.claude-opus-5-5"),
    ("anthropic.claude-haiku-5-5", "us.anthropic.claude-haiku-5-5"),
]
QUOTA_NAME = {
    "anthropic.claude-opus-5-5": "Claude Opus 5.5",
    "anthropic.claude-haiku-5-5": "Claude Haiku 5.5",
}


def short(exc: Exception) -> str:
    """HTTP status and the provider's own message, without the request ID noise."""
    body = getattr(exc, "body", None)  # anthropic.APIStatusError
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        return f"{exc.status_code} {body['error'].get('message')}"  # type: ignore[attr-defined]
    error = getattr(exc, "response", {}).get("Error", {})  # botocore.ClientError
    if error:
        return f"{error.get('Code')}: {error.get('Message')}"
    return f"{type(exc).__name__}: {exc}"


def availability(bedrock: Any, model: str) -> tuple[bool, str]:
    try:
        a = bedrock.get_foundation_model_availability(modelId=model)
    except Exception as exc:
        return False, short(exc)
    agreement = a["agreementAvailability"]["status"]
    ok = (
        a["authorizationStatus"] == "AUTHORIZED"
        and agreement == "AVAILABLE"
        and a["entitlementAvailability"] == "AVAILABLE"
        and a["regionAvailability"] == "AVAILABLE"
    )
    detail = (
        f"authorization={a['authorizationStatus']} agreement={agreement} "
        f"entitlement={a['entitlementAvailability']} region={a['regionAvailability']}"
    )
    return ok, detail


def quotas(sq: Any, family: str) -> list[tuple[str, float, float | None]]:
    """(name, applied value, AWS default) for per-minute inference quotas of one model family."""
    rows = []
    for page in sq.get_paginator("list_service_quotas").paginate(ServiceCode="bedrock"):
        for q in page["Quotas"]:
            name = q["QuotaName"]
            if family in name and "per minute" in name and "batch" not in name.lower():
                try:
                    code = q["QuotaCode"]
                    default_value = sq.get_aws_default_service_quota(ServiceCode="bedrock", QuotaCode=code)[
                        "Quota"
                    ]["Value"]
                except Exception:
                    default_value = None
                rows.append((name, q["Value"], default_value))
    return rows


def call_messages(model: str) -> tuple[bool, str]:
    from anthropic import AnthropicBedrockMantle

    try:
        msg = AnthropicBedrockMantle(aws_region=REGION).messages.create(
            model=model, max_tokens=16, messages=[{"role": "user", "content": "Say ok"}]
        )
        return True, f"stop_reason={msg.stop_reason} usage={msg.usage.input_tokens}/{msg.usage.output_tokens}"
    except Exception as exc:
        return False, short(exc)


def call_converse(runtime: Any, profile: str) -> tuple[bool, str]:
    try:
        r = runtime.converse(
            modelId=profile,
            messages=[{"role": "user", "content": [{"text": "Say ok"}]}],
            inferenceConfig={"maxTokens": 16},
        )
        usage = r["usage"]
        return True, f"stopReason={r['stopReason']} usage={usage['inputTokens']}/{usage['outputTokens']}"
    except Exception as exc:
        return False, short(exc)


def main() -> int:
    sts = boto3.client("sts", region_name=REGION)
    bedrock = boto3.client("bedrock", region_name=REGION)
    runtime = boto3.client("bedrock-runtime", region_name=REGION)
    sq = boto3.client("service-quotas", region_name=REGION)
    print(f"Account {sts.get_caller_identity()['Account']}, region {REGION}\n")

    ready: list[str] = []
    for model, profile in MODELS:
        print(f"== {model}")
        ok_access, detail = availability(bedrock, model)
        print(f"   access      {'OK  ' if ok_access else 'FAIL'} {detail}")
        rows = quotas(sq, QUOTA_NAME[model])
        zero = [r for r in rows if r[1] == 0]
        for name, applied, default in rows:
            mark = "FAIL" if applied == 0 else "OK  "
            print(f"   quota       {mark} applied={applied:>12,.0f} default={default or 0:>12,.0f}  {name}")
        ok_msg, detail = call_messages(model)
        status = "OK  " if ok_msg else "FAIL"
        print(f"   messages    {status} PARSER_PROVIDER=bedrock {model}: {detail}")
        if ok_msg:
            ready.append(f"PARSER_PROVIDER=bedrock PARSER_MODEL={model}")
        ok_conv, detail = call_converse(runtime, profile)
        status = "OK  " if ok_conv else "FAIL"
        print(f"   converse    {status} PARSER_PROVIDER=bedrock-converse {profile}: {detail}")
        if ok_conv:
            ready.append(f"PARSER_PROVIDER=bedrock-converse PARSER_MODEL={profile}")
        if zero and not (ok_msg or ok_conv):
            print(f"   -> {len(zero)} inference quota(s) are 0 on this account: AWS has to raise them.")
        print()

    if ready:
        print("READY. Switch the parser in infra/terraform.tfvars (pull request, merge) with one of:")
        for line in ready:
            provider, model = (part.split("=", 1)[1] for part in line.split())
            print(f'   parser_provider = "{provider}"   parser_model = "{model}"')
        return 0
    print("BLOCKED: no Claude model answers on this account. Keep PARSER_PROVIDER=openai (see ADR 0006).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
