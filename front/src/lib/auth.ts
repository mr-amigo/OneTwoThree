/**
 * Sign-in with Amazon Cognito managed login (OpenID Connect, authorization code + PKCE).
 *
 * The app never shows a password form. `/login/` sends the browser to Cognito's sign-in page, which
 * offers email + password (with sign-up and the emailed code) and Continue with Google. Cognito
 * talks to Google; for this app a Google user and a password user both come back as Cognito tokens.
 * The OIDC library keeps the random `state` and the PKCE verifier in the browser, so a login has
 * to start in this app (`/login/`), not at a hand-copied Cognito URL.
 *
 * Without VITE_COGNITO_CLIENT_ID (local development without AWS) auth is off: the backend treats
 * every request as one local user and /login/ only offers to continue as that user.
 */

import {
  UserManager,
  WebStorageStateStore,
  type CreateSigninRequestArgs,
  type SigninRequest,
} from "oidc-client-ts"

export interface AuthConfig {
  region: string
  userPoolId: string
  clientId: string
  /** Cognito domain without scheme, e.g. meetings-1234.auth.us-east-1.amazoncognito.com. */
  domain: string
}

export function authConfig(): AuthConfig {
  const env = import.meta.env
  return {
    region: env.VITE_COGNITO_REGION || "us-east-1",
    userPoolId: env.VITE_COGNITO_USER_POOL_ID ?? "",
    clientId: env.VITE_COGNITO_CLIENT_ID ?? "",
    domain: env.VITE_COGNITO_DOMAIN ?? "",
  }
}

export const authEnabled = () => {
  const { clientId, userPoolId } = authConfig()
  return Boolean(clientId && userPoolId)
}

// Must be listed, character for character, in the app client's CallbackURLs / LogoutURLs.
export const callbackUrl = () => `${window.location.origin}/auth/callback`
export const logoutRedirectUrl = () => `${window.location.origin}/`

/** Cognito has no standard OIDC end-session endpoint; its own /logout also ends its cookie session. */
export function cognitoLogoutUrl(): string {
  const { clientId, domain } = authConfig()
  const params = new URLSearchParams({ client_id: clientId, logout_uri: logoutRedirectUrl() })
  return `https://${domain}/logout?${params}`
}

/**
 * `createSigninRequest` exists only on the library's inner OidcClient, which UserManager keeps
 * protected. It builds the authorize URL and saves the `state` and PKCE verifier in the browser
 * (what the callback checks), without navigating. The sign-up button needs exactly that.
 */
export class AppUserManager extends UserManager {
  createSigninRequest(args: CreateSigninRequestArgs = {}): Promise<SigninRequest> {
    return this._client.createSigninRequest(args)
  }
}

let manager: { key: string; instance: AppUserManager } | null = null

/** The one OIDC client of this page; also handed to the React provider. */
export function getUserManager(): AppUserManager {
  const { region, userPoolId, clientId } = authConfig()
  const key = [region, userPoolId, clientId, window.location.origin].join("|")
  if (manager?.key !== key) {
    manager = {
      key,
      instance: new AppUserManager({
        authority: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
        client_id: clientId,
        redirect_uri: callbackUrl(),
        post_logout_redirect_uri: logoutRedirectUrl(),
        response_type: "code",
        scope: "openid email profile",
        // localStorage, so a reload or a second tab stays signed in.
        userStore: new WebStorageStateStore({ store: window.localStorage }),
        // Renews with the refresh token shortly before the tokens expire.
        automaticSilentRenew: true,
      }),
    }
  }
  return manager.instance
}

/**
 * Cognito's sign-up page takes the same parameters as /oauth2/authorize, so the sign-up URL is the
 * authorize URL with another path. Everything else (client_id, redirect_uri, state, code_challenge)
 * stays, so after confirming the account the user comes back to /auth/callback like any sign-in.
 */
export function toSignupUrl(authorizeUrl: string): string {
  const url = new URL(authorizeUrl)
  if (!url.pathname.endsWith("/oauth2/authorize")) {
    throw new Error(`Unexpected authorization endpoint: ${url.pathname}`)
  }
  url.pathname = url.pathname.replace(/\/oauth2\/authorize$/, "/signup")
  return url.toString()
}

/** Opens Cognito's sign-up page; the login started here, so the callback finds its state. */
export async function startSignUp(): Promise<void> {
  const request = await getUserManager().createSigninRequest()
  window.location.assign(toSignupUrl(request.url))
}

// --- Auth off (local development): a flag in localStorage stands in for the session ---

const LOCAL_SESSION_KEY = "meetings.session"

export const isLocalSignedIn = () => localStorage.getItem(LOCAL_SESSION_KEY) !== null
export const localSignIn = () => localStorage.setItem(LOCAL_SESSION_KEY, "local")
export const localSignOut = () => localStorage.removeItem(LOCAL_SESSION_KEY)

// --- What the API needs ---

/**
 * The token sent to the API as `Authorization: Bearer`, renewed when expired; null when signed out.
 * Today it is the ID token, which carries the email the API stores for the user.
 */
export async function getApiToken(): Promise<string | null> {
  if (!authEnabled()) return null
  const users = getUserManager()
  let user = await users.getUser()
  if (user?.expired) {
    try {
      user = await users.signinSilent()
    } catch {
      user = null
    }
  }
  return user?.id_token ?? null
}

/** Forgets the session in this browser only, without visiting Cognito (used when the API rejects it). */
export async function clearSession(): Promise<void> {
  localSignOut()
  if (authEnabled()) await getUserManager().removeUser()
}
