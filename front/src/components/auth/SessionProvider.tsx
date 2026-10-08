import { useState, type ReactNode } from "react"
import { AuthProvider, useAuth } from "react-oidc-context"

import {
  authEnabled,
  cognitoLogoutUrl,
  getUserManager,
  isLocalSignedIn,
  localSignIn,
  localSignOut,
  startSignUp,
} from "@/lib/auth"
import { SessionContext, type Session } from "@/lib/session-context"

/** Cognito mode: react-oidc-context finishes the redirect (`?code=…&state=…`) on its own. */
function CognitoSession({ children }: { children: ReactNode }) {
  const auth = useAuth()
  const session: Session = {
    isLoading: auth.isLoading,
    isAuthenticated: auth.isAuthenticated,
    email: auth.user?.profile.email ?? null,
    error: auth.error ?? null,
    signIn: () => auth.signinRedirect(),
    signUp: startSignUp,
    signInWithGoogle: () =>
      auth.signinRedirect({ extraQueryParams: { identity_provider: "Google" } }),
    signOut: async () => {
      await auth.removeUser()
      window.location.assign(cognitoLogoutUrl())
    },
  }
  return <SessionContext value={session}>{children}</SessionContext>
}

/** Auth-off mode (local development): signing in is a flag in localStorage. */
function LocalSession({ children }: { children: ReactNode }) {
  const [signedIn, setSignedIn] = useState(isLocalSignedIn)
  const session: Session = {
    isLoading: false,
    isAuthenticated: signedIn,
    email: null,
    error: null,
    signIn: async () => {
      localSignIn()
      setSignedIn(true)
    },
    // There is no Cognito here, so these can only mean "continue as the local user" too.
    signUp: async () => {
      localSignIn()
      setSignedIn(true)
    },
    signInWithGoogle: async () => {
      localSignIn()
      setSignedIn(true)
    },
    signOut: async () => {
      localSignOut()
      setSignedIn(false)
    },
  }
  return <SessionContext value={session}>{children}</SessionContext>
}

export function SessionProvider({ children }: { children: ReactNode }) {
  if (!authEnabled()) return <LocalSession>{children}</LocalSession>
  return (
    <AuthProvider
      userManager={getUserManager()}
      // Drop ?code=…&state=… from the address bar once the code has been exchanged.
      onSigninCallback={() =>
        window.history.replaceState({}, document.title, window.location.pathname)
      }
    >
      <CognitoSession>{children}</CognitoSession>
    </AuthProvider>
  )
}
