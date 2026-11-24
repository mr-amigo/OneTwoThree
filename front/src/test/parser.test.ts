import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

vi.mock("@/lib/auth", () => ({
  getApiToken: async () => "id-token",
  clearSession: async () => {},
}))

const URL = "https://parser.example.lambda-url.us-east-1.on.aws/"

async function load() {
  vi.resetModules()
  vi.stubEnv("VITE_PARSER_URL", URL)
  return import("@/lib/parser")
}

function respond(status: number, body: unknown) {
  return vi
    .spyOn(globalThis, "fetch")
    .mockResolvedValue(new Response(JSON.stringify(body), { status }))
}

describe("parseAgenda", () => {
  beforeEach(() => vi.restoreAllMocks())
  afterEach(() => vi.unstubAllEnvs())

  it("posts the text with the user's date and time zone and the ID token", async () => {
    const { parseAgenda, parserEnabled } = await load()
    const fetchMock = respond(200, {
      agenda: { items: [], action_items: [], language: "en" },
      model: "gpt-5.4-mini",
      prompt_version: "agenda-v1",
    })
    const result = await parseAgenda("Mon 10:00 sync", new AbortController().signal)

    expect(parserEnabled()).toBe(true)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe(URL.replace(/\/$/, ""))
    expect((init?.headers as Record<string, string>).Authorization).toBe("Bearer id-token")
    const body = JSON.parse(String(init?.body))
    expect(body.text).toBe("Mon 10:00 sync")
    expect(body.today).toMatch(/^\d{4}-\d{2}-\d{2}$/)
    expect(body.tz).toBe(Intl.DateTimeFormat().resolvedOptions().timeZone)
    expect(result.model).toBe("gpt-5.4-mini")
  })

  it.each([
    [413, {}, "too long"],
    [429, {}, "busy"],
    [502, {}, "unavailable"],
    [422, { error: "no agenda found in the text" }, "no agenda found in the text"],
  ])("turns HTTP %i into a clear message", async (status, body, text) => {
    const { parseAgenda } = await load()
    respond(status, body)
    await expect(parseAgenda("x", new AbortController().signal)).rejects.toThrow(text)
  })

  it("explains a network failure", async () => {
    const { parseAgenda } = await load()
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("Failed to fetch"))
    await expect(parseAgenda("x", new AbortController().signal)).rejects.toThrow(/Network error/)
  })
})
