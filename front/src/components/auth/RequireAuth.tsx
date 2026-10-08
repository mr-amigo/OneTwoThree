import type { ReactNode } from "react"
import { Navigate } from "react-router"

import { useSession } from "@/lib/session-context"

/** Renders the page only with a session; otherwise starts the sign-in at /login/. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading } = useSession()
  if (isLoading) return null
  return isAuthenticated ? children : <Navigate to="/login/" replace />
}
