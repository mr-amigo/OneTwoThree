import { LoaderCircle } from "lucide-react"
import { Link, Navigate } from "react-router"

import { AuthLayout } from "@/components/auth/AuthLayout"
import { useSession } from "@/lib/session-context"

/**
 * Where Cognito sends the browser back with `?code=…&state=…`. The OIDC provider exchanges the code
 * for tokens as soon as the app loads; this page only waits for that and shows what happened.
 */
export function AuthCallbackPage() {
  const { isAuthenticated, isLoading, error } = useSession()

  if (isAuthenticated) return <Navigate to="/home" replace />
  // Nothing to finish (opened by hand, or the code was already used): start over.
  if (!isLoading && !error) return <Navigate to="/login/" replace />

  return (
    <AuthLayout>
      {error ? (
        <div role="alert">
          <h1 className="text-2xl font-semibold text-foreground">Sign-in failed</h1>
          <p className="mt-2 text-sm text-muted-foreground">{error.message}</p>
          <Link
            to="/login/"
            className="mt-6 inline-block font-medium text-primary underline-offset-4 hover:underline"
          >
            Try again
          </Link>
        </div>
      ) : (
        <p className="flex items-center gap-2 text-muted-foreground">
          <LoaderCircle className="size-5 animate-spin" /> Signing you in…
        </p>
      )}
    </AuthLayout>
  )
}
