import { clearSession, getApiToken } from "@/lib/auth"
import type { AiSuggestion } from "@/types"

// The agenda-parser Lambda function URL, set at build time. Empty = the feature is not configured.
// (Locally it can be /api/ai/parse-agenda when the backend runs with PARSER_LOCAL_ENDPOINT=true.)
const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? "").replace(/\/+$/, "")

export const parserEnabled = () => Boolean(PARSER_URL)

export class ParserError extends Error {}

const FALLBACK = "You can still type the agenda by hand."

const MESSAGES: Record<number, string> = {
  413: "The text is too long (10,000 characters at most).",
  429: `The AI service is busy. Try again in a minute. ${FALLBACK}`,
  502: `The AI service is unavailable. ${FALLBACK}`,
  503: `The sign-in check is unavailable. Try again. ${FALLBACK}`,
}

function localDate(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0")
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/** Sends pasted text to the parser. The result is a suggestion: nothing is saved by it. */
export async function parseAgenda(text: string, signal: AbortSignal): Promise<AiSuggestion> {
  const token = await getApiToken()
  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: "POST",
      signal,
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      // "Monday" means the user's Monday, so the browser sends its date and time zone.
      body: JSON.stringify({
        text,
        today: localDate(),
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") throw error
    throw new ParserError(`Network error: the parser could not be reached. ${FALLBACK}`)
  }

  if (response.status === 401) {
    await clearSession()
    window.location.assign("/")
  }
  if (!response.ok) {
    let message = MESSAGES[response.status]
    if (!message && response.status === 422) {
      const body = (await response.json().catch(() => null)) as { error?: string } | null
      message = `${body?.error ?? "The text could not be parsed."} ${FALLBACK}`
    }
    throw new ParserError(message ?? `Parsing failed (${response.status}). ${FALLBACK}`)
  }
  const body = await response.json()
  return {
    agenda: body.agenda,
    model: body.model,
    prompt_version: body.prompt_version,
  }
}
