import { createContext, useContext } from "react"

/** What the UI needs to know about the signed-in user, whether auth is on (Cognito) or off. */
export interface Session {
  /** True while the stored session is being restored or a sign-in redirect is being completed. */
  isLoading: boolean
  isAuthenticated: boolean
  /** The signed-in user's email from the token; null when signed out (or with auth off). */
  email: string | null
  error: Error | null
  /** Starts sign-in: redirects to Cognito's page (auth on) or signs in as the local user (auth off). */
  signIn: () => Promise<void>
  /** Opens Cognito's sign-up page (a full-page redirect); with auth off it signs in locally. */
  signUp: () => Promise<void>
  /** Goes straight to Google through Cognito, skipping Cognito's page; with auth off, as signIn. */
  signInWithGoogle: () => Promise<void>
  /** Ends the session here and at Cognito (a full-page redirect), so the next sign-in asks again. */
  signOut: () => Promise<void>
}

export const SessionContext = createContext<Session | null>(null)

export function useSession(): Session {
  const session = useContext(SessionContext)
  if (!session) throw new Error("useSession must be used inside <SessionProvider>")
  return session
}
