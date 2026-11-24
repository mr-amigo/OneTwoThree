import { screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { AgendaDialog } from "@/components/AgendaDialog"
import { mockFetch, renderWithQuery, sampleMeeting } from "@/test/utils"
import type { AiSuggestion } from "@/types"

const { parseAgenda } = vi.hoisted(() => ({ parseAgenda: vi.fn() }))
vi.mock("@/lib/parser", () => ({ parserEnabled: () => true, parseAgenda }))

const SUGGESTION: AiSuggestion = {
  agenda: {
    title: "Pricing sync",
    starts_at: "2026-11-30T10:00:00+02:00",
    duration_minutes: 45,
    items: [
      { topic: "New Pro plans", owner: "Olena", minutes: 15 },
      { topic: "Customer feedback", owner: "Taras", minutes: null },
    ],
    action_items: [{ task: "Compare competitors", owner: "Taras", due: "2026-11-27" }],
    language: "en",
  },
  model: "gpt-5.4-mini",
  prompt_version: "agenda-v1",
}

function renderDialog() {
  const fetchMock = mockFetch(() => ({ body: { ...sampleMeeting } }))
  renderWithQuery(<AgendaDialog meeting={sampleMeeting} onClose={() => {}} />)
  return fetchMock
}

async function pasteAndParse(text = "Mon 10:00 pricing sync") {
  await userEvent.type(screen.getByRole("textbox", { name: "Paste an agenda" }), text)
  await userEvent.click(screen.getByRole("button", { name: "Parse" }))
}

describe("AgendaDialog", () => {
  beforeEach(() => {
    parseAgenda.mockReset()
  })

  it("pre-fills the form, marks suggested fields and leaves empty ones empty", async () => {
    parseAgenda.mockResolvedValue(SUGGESTION)
    renderDialog()
    await pasteAndParse()

    expect(await screen.findByLabelText("Topic 1")).toHaveValue("New Pro plans")
    expect(screen.getByLabelText("Owner 2")).toHaveValue("Taras")
    expect(screen.getByLabelText("Minutes 2")).toHaveValue("")
    expect(screen.getByLabelText("Due 1")).toHaveValue("2026-11-27")
    // 3 + 2 item fields and 3 action fields were filled by the model; "Minutes 2" was not.
    expect(screen.getAllByText("suggested")).toHaveLength(8)
    expect(screen.getByTestId("detected")).toHaveTextContent("gpt-5.4-mini (agenda-v1)")
    expect(parseAgenda.mock.calls[0][0]).toBe("Mon 10:00 pricing sync")
  })

  it("drops the badge of a field the user corrects, and saves with the suggestion", async () => {
    parseAgenda.mockResolvedValue(SUGGESTION)
    const fetchMock = renderDialog()
    await pasteAndParse()

    const owner = await screen.findByLabelText("Owner 1")
    await userEvent.clear(owner)
    await userEvent.type(owner, "Olena K.")
    expect(screen.getAllByText("suggested")).toHaveLength(7)

    await userEvent.click(screen.getByRole("button", { name: "Save agenda" }))
    await waitFor(() =>
      expect(fetchMock).toHaveBeenCalledWith(
        `/api/meetings/${sampleMeeting.id}/agenda`,
        expect.objectContaining({ method: "PUT" }),
      ),
    )
    const put = fetchMock.mock.calls.find(([, init]) => init?.method === "PUT")
    const body = JSON.parse(String(put?.[1]?.body))
    expect(body.agenda_items[0]).toEqual({ topic: "New Pro plans", owner: "Olena K.", minutes: 15 })
    expect(body.agenda_items[1]).toEqual({
      topic: "Customer feedback",
      owner: "Taras",
      minutes: null,
    })
    expect(body.ai_suggestion).toEqual(SUGGESTION)
  })

  it("shows the parser's error and keeps the form usable by hand", async () => {
    parseAgenda.mockImplementation(async () => {
      throw new Error("The AI service is busy. Try again in a minute.")
    })
    renderDialog()
    await pasteAndParse()

    expect(await screen.findByRole("alert")).toHaveTextContent("The AI service is busy")
    await userEvent.click(screen.getByRole("button", { name: /Add item/ }))
    expect(screen.getByLabelText("Topic 1")).toBeEnabled()
  })

  it("shows progress while waiting and cancels the request", async () => {
    let signal: AbortSignal | undefined
    parseAgenda.mockImplementation(
      (_text: string, s: AbortSignal) =>
        new Promise((_resolve, reject) => {
          signal = s
          s.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")))
        }),
    )
    renderDialog()
    await pasteAndParse()

    expect(await screen.findByRole("status")).toHaveTextContent("Reading your text")
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(signal?.aborted).toBe(true)
    await waitFor(() => expect(screen.queryByRole("status")).not.toBeInTheDocument())
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})
