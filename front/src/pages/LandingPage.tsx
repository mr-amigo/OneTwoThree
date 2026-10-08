import { useState } from "react"
import { LoaderCircle } from "lucide-react"
import { Link, Navigate } from "react-router"

import { AuthLayout } from "@/components/auth/AuthLayout"
import { SiteHeader } from "@/components/SiteHeader"
import { Button } from "@/components/ui/button"
import { authEnabled } from "@/lib/auth"
import { useSession } from "@/lib/session-context"

function GoogleIcon() {
  return (
    <svg viewBox="0 0 48 48" aria-hidden className="size-5">
      <path
        fill="#FFC107"
        d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"
      />
      <path
        fill="#FF3D00"
        d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-7.9l-6.5 5C9.5 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"
      />
    </svg>
  )
}

/**
 * The public front page, laid out like the old sign-in page. It has no forms: "Sign in" goes to
 * /login/ (which redirects to Cognito's page), and the other two buttons start a Cognito sign-up
 * or Google sign-in from here, so state and PKCE are saved in this browser first.
 */
export function LandingPage() {
  const { isAuthenticated, isLoading, signUp, signInWithGoogle } = useSession()
  const [failed, setFailed] = useState(false)
  const cognito = authEnabled()

  if (isAuthenticated) return <Navigate to="/home" replace />

  const run = (start: () => Promise<void>) => () => {
    setFailed(false)
    start().catch(() => setFailed(true))
  }

  return (
    <div className="flex min-h-screen flex-col">
      <SiteHeader />
      <AuthLayout className="min-h-0 flex-1" mobileBrand={false}>
        <h1 className="text-2xl font-semibold text-foreground">Sign in</h1>
        {isLoading ? (
          <p className="mt-4 flex items-center gap-2 text-sm text-muted-foreground">
            <LoaderCircle className="size-4 animate-spin" /> Checking your session…
          </p>
        ) : (
          <>
            <p className="mt-1.5 text-sm text-muted-foreground">
              {cognito
                ? "Sign in or create an account to see your meetings."
                : "Sign-in is not configured here, so every request acts as one local user."}
            </p>
            <div className="mt-8 space-y-3">
              <Button asChild className="h-10 w-full">
                <Link to="/login/">Sign in</Link>
              </Button>
              {cognito && (
                <>
                  <Button
                    type="button"
                    variant="outline"
                    className="h-10 w-full"
                    onClick={run(signUp)}
                  >
                    Create account
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    className="h-10 w-full gap-2.5"
                    onClick={run(signInWithGoogle)}
                  >
                    <GoogleIcon /> Continue with Google
                  </Button>
                </>
              )}
            </div>
            {failed && (
              <p role="alert" className="mt-4 text-sm text-destructive">
                Could not reach the sign-in page, try again.
              </p>
            )}
          </>
        )}
      </AuthLayout>
    </div>
  )
}
