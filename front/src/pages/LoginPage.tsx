import { useEffect, useRef } from "react"
import { LoaderCircle } from "lucide-react"
import { Navigate } from "react-router"

import { AuthLayout } from "@/components/auth/AuthLayout"
import { Button } from "@/components/ui/button"
import { authEnabled } from "@/lib/auth"
import { useSession } from "@/lib/session-context"

/**
 * /login/ is the address to hand in: it starts the sign-in from this app and goes straight to
 * Cognito's page (email + password, or Continue with Google). Starting here matters because the
 * library saves the `state` and PKCE verifier in this browser before redirecting; without them the
 * callback would reject the code.
 */
export function LoginPage() {
  const { isAuthenticated, isLoading, error, signIn } = useSession()
  const started = useRef(false)
  const cognito = authEnabled()

  // A failed redirect (Cognito unreachable) is reported through `error`, not thrown.
  const start = () => void signIn()

  useEffect(() => {
    if (!cognito || isLoading || isAuthenticated || started.current) return
    started.current = true
    start()
    // start() depends on nothing that changes; the ref makes this run once.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cognito, isLoading, isAuthenticated])

  if (isAuthenticated) return <Navigate to="/home" replace />

  return (
    <AuthLayout>
      <h1 className="text-2xl font-semibold text-foreground">Sign in</h1>
      {cognito ? (
        error ? (
          <div role="alert" className="mt-4">
            <p className="text-sm text-destructive">
              {error.message || "Could not reach the sign-in page"}
            </p>
            <Button className="mt-4 h-10 w-full" onClick={start}>
              Try again
            </Button>
          </div>
        ) : (
          <p className="mt-4 flex items-center gap-2 text-sm text-muted-foreground">
            <LoaderCircle className="size-4 animate-spin" /> Redirecting to the sign-in page…
          </p>
        )
      ) : (
        <>
          <p className="mt-1.5 text-sm text-muted-foreground">
            Sign-in is not configured here (no Cognito settings), so every request acts as one local
            user.
          </p>
          <Button className="mt-6 h-10 w-full" onClick={start}>
            Continue as local developer
          </Button>
        </>
      )}
    </AuthLayout>
  )
}
