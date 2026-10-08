import { useQueryClient } from "@tanstack/react-query"
import { CalendarDays, LogIn, LogOut, Plus } from "lucide-react"
import { Link, useNavigate } from "react-router"

import { useMe } from "@/hooks/useMe"
import { useSession } from "@/lib/session-context"

interface SiteHeaderProps {
  /** Opens the new-meeting form; the button is shown only when signed in. */
  onNewMeeting?: () => void
}

export function SiteHeader({ onNewMeeting }: SiteHeaderProps) {
  const { isAuthenticated, email, signOut } = useSession()
  const { data: me } = useMe(isAuthenticated)
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  // The email in the token; the API's copy covers local development, where there is no token.
  const shownEmail = email ?? me?.email

  const handleSignOut = async () => {
    queryClient.clear()
    await signOut()
    navigate("/", { replace: true })
  }

  return (
    <header className="sticky top-0 z-40 bg-brand text-white shadow-[0_0.8px_8px_rgba(0,0,0,0.2)]">
      <div className="mx-auto flex h-14 max-w-7xl items-center gap-8 px-4 sm:px-6">
        <Link to={isAuthenticated ? "/home" : "/"} className="flex items-center gap-2.5">
          <span className="flex size-9 items-center justify-center rounded-sm border-2 border-white/90">
            <CalendarDays className="size-5" />
          </span>
          <span className="font-serif text-sm leading-tight">
            Meetings
            <br />
            <span className="text-white/80">Scheduler</span>
          </span>
        </Link>

        {isAuthenticated && (
          <nav className="hidden h-full items-stretch gap-6 text-sm sm:flex">
            <Link
              to="/home"
              className="flex items-center border-b-[3px] border-white pt-[3px] font-medium"
            >
              Meetings
            </Link>
          </nav>
        )}

        <div className="ml-auto flex items-center gap-4">
          {isAuthenticated ? (
            <>
              {onNewMeeting && (
                <>
                  <button
                    type="button"
                    onClick={onNewMeeting}
                    className="flex items-center gap-1.5 text-sm font-semibold hover:text-white/80"
                  >
                    <Plus className="size-4" /> New meeting
                  </button>
                  <span className="h-8 w-px bg-white/30" />
                </>
              )}
              {shownEmail && (
                <span
                  className="hidden max-w-56 truncate text-sm text-white/90 sm:inline"
                  title={shownEmail}
                >
                  {shownEmail}
                </span>
              )}
              <button
                type="button"
                onClick={handleSignOut}
                className="flex items-center gap-1.5 text-sm text-white/90 hover:text-white"
                aria-label="Sign out"
              >
                <LogOut className="size-4" />
                <span className="hidden md:inline">Sign out</span>
              </button>
            </>
          ) : (
            <Link
              to="/login/"
              className="flex items-center gap-1.5 text-sm font-semibold hover:text-white/80"
            >
              <LogIn className="size-4" /> Sign in
            </Link>
          )}
        </div>
      </div>
    </header>
  )
}
