import type { ReactNode } from "react"
import { CalendarDays, CalendarRange, Link2, Users } from "lucide-react"

import { cn } from "@/lib/utils"

const HIGHLIGHTS = [
  { icon: CalendarRange, text: "Week and day calendar of every meeting" },
  { icon: Users, text: "Participants on each meeting" },
  { icon: Link2, text: "Call link or place, one click away" },
]

/** Two-column frame for the sign-in and sign-up pages: brand panel left, form right. */
interface AuthLayoutProps {
  children: ReactNode
  /** Height of the frame; full screen unless a header sits above it. */
  className?: string
  /** The small logo above the form on narrow screens; off when a header already shows it. */
  mobileBrand?: boolean
}

export function AuthLayout({
  children,
  className = "min-h-screen",
  mobileBrand = true,
}: AuthLayoutProps) {
  return (
    <div className={cn("grid lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]", className)}>
      <aside className="relative hidden overflow-hidden bg-brand text-white lg:flex lg:flex-col lg:justify-between lg:p-12">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_85%_15%,rgba(255,255,255,0.14),transparent_45%),radial-gradient(circle_at_10%_95%,rgba(0,0,0,0.25),transparent_50%)]" />
        <div className="relative flex items-center gap-3">
          <span className="flex size-11 items-center justify-center rounded-sm border-2 border-white/90">
            <CalendarDays className="size-6" />
          </span>
          <span className="font-serif text-[15px] leading-tight">
            Meetings
            <br />
            <span className="text-white/80">Scheduler</span>
          </span>
        </div>
        <div className="relative max-w-md">
          <p className="font-serif text-3xl leading-snug">
            Plan meetings, invite people and know where to be.
          </p>
          <ul className="mt-8 space-y-3 text-white/90">
            {HIGHLIGHTS.map(({ icon: Icon, text }) => (
              <li key={text} className="flex items-center gap-3">
                <Icon className="size-5 shrink-0 text-white/70" /> {text}
              </li>
            ))}
          </ul>
        </div>
        <p className="relative text-sm text-white/60">
          © {new Date().getFullYear()} Meetings Scheduler
        </p>
      </aside>

      <main className="flex flex-col items-center justify-center px-4 py-10 sm:px-6">
        {mobileBrand && (
          <div className="mb-8 flex items-center gap-2.5 text-brand lg:hidden">
            <span className="flex size-10 items-center justify-center rounded-sm border-2 border-brand">
              <CalendarDays className="size-5" />
            </span>
            <span className="font-serif text-sm leading-tight">
              Meetings
              <br />
              Scheduler
            </span>
          </div>
        )}
        <div className="w-full max-w-sm">{children}</div>
      </main>
    </div>
  )
}
