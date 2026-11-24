# List prices in USD per 1,000,000 tokens: (input, output).
PRICES: dict[str, tuple[float, float]] = {
    # Anthropic list prices, as in the lab. Bedrock's own price page is the one that counts for the bill.
    "anthropic.claude-opus-5-5": (4.00, 20.00),
    "anthropic.claude-sonnet-5-5": (2.00, 10.00),
    "anthropic.claude-haiku-5-5": (0.10, 0.50),
    "amazon.nova-micro-v1:0": (0.035, 0.14),
    # OpenAI list prices (openai.com/api/pricing); reasoning tokens are billed as output.
    "gpt-5.4-mini": (0.75, 4.50),
    "gpt-5.4-nano": (0.20, 1.25),
}

# Bedrock inference profiles: "global." is the list price, a regional one ("us.", "eu.", …) costs 10% more.
REGIONAL_PROFILES = ("us.", "eu.", "apac.", "jp.", "au.", "ca.")
REGIONAL_MARKUP = 1.10


def price_of(model: str) -> tuple[float, float] | None:
    """Prices for a model ID or a Bedrock inference profile ID (us.anthropic.…, global.anthropic.…)."""
    markup = 1.0
    if model.startswith("global."):
        model = model.removeprefix("global.")
    elif model.startswith(REGIONAL_PROFILES):
        model, markup = model.split(".", 1)[1], REGIONAL_MARKUP
    if model not in PRICES:
        return None
    price_in, price_out = PRICES[model]
    return price_in * markup, price_out * markup


def cost_usd(model: str, usage: dict[str, int]) -> float | None:
    """Cost in dollars, or None when the model has no configured price."""
    prices = price_of(model)
    if prices is None:
        return None
    price_in, price_out = prices
    total = usage.get("input_tokens", 0) * price_in + usage.get("output_tokens", 0) * price_out
    return round(total / 1_000_000, 6)
