import { useEffect, useRef, useState } from "react"
import { Plus, Sparkles, Trash2 } from "lucide-react"
import { toast } from "sonner"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { useSaveAgenda } from "@/hooks/useMeetings"
import { parseAgenda, parserEnabled } from "@/lib/parser"
import type { AiSuggestion, Meeting } from "@/types"

const MAX_TEXT = 10_000

/** Fields the model filled are marked "suggested" until the user touches them. */
type Flags = Record<string, boolean>
interface ItemRow {
  topic: string
  owner: string
  minutes: string
  suggested: Flags
}
interface ActionRow {
  task: string
  owner: string
  due: string
  suggested: Flags
}

/** What the text says about the meeting itself. Shown for reference: the meeting is edited in its own form. */
function Detected({ suggestion }: { suggestion: AiSuggestion }) {
  const { title, starts_at, duration_minutes, language } = suggestion.agenda
  const facts = [
    title && `title “${title}”`,
    starts_at &&
      `starts ${new Date(starts_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}`,
    duration_minutes && `${duration_minutes} min`,
    language && `language ${language}`,
  ].filter(Boolean)
  return (
    <p className="text-xs text-muted-foreground" data-testid="detected">
      {facts.length > 0 && <>Also in the text: {facts.join(", ")}. </>}
      Suggested by {suggestion.model} ({suggestion.prompt_version}). Check every field before
      saving.
    </p>
  )
}

const emptyItem = (): ItemRow => ({ topic: "", owner: "", minutes: "", suggested: {} })
const emptyAction = (): ActionRow => ({ task: "", owner: "", due: "", suggested: {} })
const flagFilled = (values: Record<string, string>): Flags =>
  Object.fromEntries(Object.entries(values).map(([key, value]) => [key, value !== ""]))

function Suggested({ show }: { show: boolean }) {
  return show ? (
    <Badge variant="secondary" className="gap-1">
      <Sparkles className="size-3" /> suggested
    </Badge>
  ) : null
}

function itemsOf(meeting: Meeting): ItemRow[] {
  return (meeting.agenda_items ?? []).map((i) => ({
    topic: i.topic,
    owner: i.owner ?? "",
    minutes: i.minutes?.toString() ?? "",
    suggested: {},
  }))
}

function actionsOf(meeting: Meeting): ActionRow[] {
  return (meeting.action_items ?? []).map((a) => ({
    task: a.task,
    owner: a.owner ?? "",
    due: a.due ?? "",
    suggested: {},
  }))
}

interface AgendaDialogProps {
  meeting: Meeting
  onClose: () => void
}

/** Paste an agenda -> the model suggests -> the form is pre-filled -> the user checks it and saves. */
export function AgendaDialog({ meeting, onClose }: AgendaDialogProps) {
  const save = useSaveAgenda()
  const abort = useRef<AbortController | null>(null)
  const [text, setText] = useState("")
  const [parsing, setParsing] = useState(false)
  const [parseError, setParseError] = useState<string | null>(null)
  const [suggestion, setSuggestion] = useState<AiSuggestion | null>(meeting.ai_suggestion ?? null)
  const [items, setItems] = useState<ItemRow[]>(() => itemsOf(meeting))
  const [actions, setActions] = useState<ActionRow[]>(() => actionsOf(meeting))
  const [formError, setFormError] = useState<string | null>(null)
  const [fresh, setFresh] = useState(false)

  // Closing the dialog stops a parse that is still running: nobody will read it, and tokens cost money.
  useEffect(() => () => abort.current?.abort(), [])

  const runParse = async () => {
    const controller = new AbortController()
    abort.current = controller
    setParsing(true)
    setParseError(null)
    try {
      const result = await parseAgenda(text, controller.signal)
      setSuggestion(result)
      setFresh(true)
      setItems(
        result.agenda.items.map((i) => {
          const values = {
            topic: i.topic,
            owner: i.owner ?? "",
            minutes: i.minutes?.toString() ?? "",
          }
          return { ...values, suggested: flagFilled(values) }
        }),
      )
      setActions(
        result.agenda.action_items.map((a) => {
          const values = { task: a.task, owner: a.owner ?? "", due: a.due ?? "" }
          return { ...values, suggested: flagFilled(values) }
        }),
      )
      setFormError(null)
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return
      setParseError(error instanceof Error ? error.message : "Parsing failed")
    } finally {
      setParsing(false)
    }
  }

  const editItem = (index: number, field: "topic" | "owner" | "minutes", value: string) =>
    setItems((rows) =>
      rows.map((row, i) =>
        i === index
          ? { ...row, [field]: value, suggested: { ...row.suggested, [field]: false } }
          : row,
      ),
    )
  const editAction = (index: number, field: "task" | "owner" | "due", value: string) =>
    setActions((rows) =>
      rows.map((row, i) =>
        i === index
          ? { ...row, [field]: value, suggested: { ...row.suggested, [field]: false } }
          : row,
      ),
    )

  const submit = () => {
    for (const row of items) {
      const minutes = row.minutes.trim()
      if (!row.topic.trim()) return setFormError("Every agenda item needs a topic.")
      if (minutes && !(/^\d+$/.test(minutes) && +minutes >= 1 && +minutes <= 480))
        return setFormError("Minutes must be a whole number from 1 to 480.")
    }
    for (const row of actions) {
      if (!row.task.trim()) return setFormError("Every action item needs a task.")
      if (row.due && !/^\d{4}-\d{2}-\d{2}$/.test(row.due))
        return setFormError("Due dates must look like 2026-10-30.")
    }
    setFormError(null)
    save.mutate(
      {
        id: meeting.id,
        data: {
          agenda_items: items.map((i) => ({
            topic: i.topic.trim(),
            owner: i.owner.trim() || null,
            minutes: i.minutes.trim() ? Number(i.minutes) : null,
          })),
          action_items: actions.map((a) => ({
            task: a.task.trim(),
            owner: a.owner.trim() || null,
            due: a.due || null,
          })),
          // What the model suggested travels with what the user saved: the difference is feedback.
          ai_suggestion: suggestion,
        },
      },
      {
        onSuccess: () => {
          toast.success("Agenda saved")
          onClose()
        },
        onError: (error) => setFormError(`Could not save the agenda: ${error.message}`),
      },
    )
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Agenda: {meeting.title}</DialogTitle>
          <DialogDescription>
            Paste an email, a chat message or notes. The AI suggests an agenda; you check it and
            save.
          </DialogDescription>
        </DialogHeader>

        {parserEnabled() ? (
          <section className="space-y-2" aria-label="Paste an agenda">
            <Textarea
              aria-label="Paste an agenda"
              placeholder="Mon 10:00, pricing sync, 45 min. 1) new Pro plans, Olena, 15 min ..."
              rows={4}
              value={text}
              maxLength={MAX_TEXT}
              onChange={(e) => setText(e.target.value)}
              disabled={parsing}
            />
            <div className="flex items-center gap-2">
              <Button onClick={runParse} disabled={parsing || !text.trim()}>
                {parsing ? "Parsing…" : "Parse"}
              </Button>
              {parsing && (
                <Button variant="outline" onClick={() => abort.current?.abort()}>
                  Cancel
                </Button>
              )}
              <span className="ml-auto text-xs text-muted-foreground">
                {text.length}/{MAX_TEXT}
              </span>
            </div>
            {parsing && (
              <p role="status" className="text-sm text-muted-foreground">
                Reading your text… this takes a few seconds.
              </p>
            )}
            {parseError && (
              <p role="alert" className="text-sm text-destructive">
                {parseError}
              </p>
            )}
            {fresh && suggestion && <Detected suggestion={suggestion} />}
          </section>
        ) : (
          <p className="text-sm text-muted-foreground">
            Parsing is not configured here. Type the agenda by hand.
          </p>
        )}

        <section className="space-y-2" aria-label="Agenda items">
          <h3 className="text-sm font-medium">Agenda items</h3>
          {items.map((row, i) => (
            <div key={i} className="grid grid-cols-[1fr_8rem_5rem_auto] items-start gap-2">
              <div className="space-y-1">
                <Input
                  aria-label={`Topic ${i + 1}`}
                  value={row.topic}
                  onChange={(e) => editItem(i, "topic", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.topic)} />
              </div>
              <div className="space-y-1">
                <Input
                  aria-label={`Owner ${i + 1}`}
                  placeholder="Owner"
                  value={row.owner}
                  onChange={(e) => editItem(i, "owner", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.owner)} />
              </div>
              <div className="space-y-1">
                <Input
                  aria-label={`Minutes ${i + 1}`}
                  placeholder="Min"
                  inputMode="numeric"
                  value={row.minutes}
                  onChange={(e) => editItem(i, "minutes", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.minutes)} />
              </div>
              <Button
                variant="ghost"
                size="icon"
                aria-label={`Remove item ${i + 1}`}
                onClick={() => setItems((rows) => rows.filter((_, j) => j !== i))}
              >
                <Trash2 />
              </Button>
            </div>
          ))}
          <Button variant="outline" size="sm" onClick={() => setItems((r) => [...r, emptyItem()])}>
            <Plus /> Add item
          </Button>
        </section>

        <section className="space-y-2" aria-label="Action items">
          <h3 className="text-sm font-medium">Action items</h3>
          {actions.map((row, i) => (
            <div key={i} className="grid grid-cols-[1fr_8rem_9rem_auto] items-start gap-2">
              <div className="space-y-1">
                <Input
                  aria-label={`Task ${i + 1}`}
                  value={row.task}
                  onChange={(e) => editAction(i, "task", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.task)} />
              </div>
              <div className="space-y-1">
                <Input
                  aria-label={`Action owner ${i + 1}`}
                  placeholder="Owner"
                  value={row.owner}
                  onChange={(e) => editAction(i, "owner", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.owner)} />
              </div>
              <div className="space-y-1">
                <Input
                  aria-label={`Due ${i + 1}`}
                  placeholder="YYYY-MM-DD"
                  value={row.due}
                  onChange={(e) => editAction(i, "due", e.target.value)}
                />
                <Suggested show={Boolean(row.suggested.due)} />
              </div>
              <Button
                variant="ghost"
                size="icon"
                aria-label={`Remove action ${i + 1}`}
                onClick={() => setActions((rows) => rows.filter((_, j) => j !== i))}
              >
                <Trash2 />
              </Button>
            </div>
          ))}
          <Button
            variant="outline"
            size="sm"
            onClick={() => setActions((r) => [...r, emptyAction()])}
          >
            <Plus /> Add action
          </Button>
        </section>

        {formError && (
          <p role="alert" className="text-sm text-destructive">
            {formError}
          </p>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
          <Button onClick={submit} disabled={save.isPending}>
            {save.isPending ? "Saving…" : "Save agenda"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
