import { screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { User, UserManager } from "oidc-client-ts"
import { beforeEach, describe, expect, it, vi } from "vitest"

import App from "@/App"
import { api } from "@/lib/api"
import { cognitoLogoutUrl, getApiToken, getUserManager, toSignupUrl } from "@/lib/auth"
import { mockFetch, renderWithQuery } from "@/test/utils"

const POOL = "us-east-1_AbCdEf123"
const DOMAIN = "meetings-123456789012.auth.us-east-1.amazoncognito.com"

/** A signed-in user as the OIDC library keeps it in localStorage. */
function cognitoUser(overrides: Partial<ConstructorParameters<typeof User>[0]> = {}) {
  const now = Math.floor(Date.now() / 1000)
  return new User({
    id_token: "id-token",
    access_token: "access-token",
    refresh_token: "refresh-token",
    token_type: "Bearer",
    scope: "openid email profile",
    expires_at: now + 3600,
    profile: {
      sub: "abc-123",
      iss: `https://cognito-idp.us-east-1.amazonaws.com/${POOL}`,
      aud: "client-123",
      exp: now + 3600,
      iat: now,
      email: "anna@example.com",
    },
    ...overrides,
  })
}

/** Answers Cognito's OIDC discovery like the real pool, and every other request with `[]`. */
function mockCognitoFetch() {
  return mockFetch((url) =>
    url.endsWith("/.well-known/openid-configuration")
      ? {
          body: {
            issuer: `https://cognito-idp.us-east-1.amazonaws.com/${POOL}`,
            authorization_endpoint: `https://${DOMAIN}/oauth2/authorize`,
            token_endpoint: `https://${DOMAIN}/oauth2/token`,
            userinfo_endpoint: `https://${DOMAIN}/oauth2/userInfo`,
          },
        }
      : { body: [] },
  )
}

/** Renders the front page and swaps `window.location` for one whose `assign` is a spy. */
function renderFrontPage() {
  const assign = vi.fn()
  vi.stubGlobal("location", { ...window.location, origin: window.location.origin, assign })
  mockCognitoFetch()
  renderWithQuery(<App />, "/")
  return assign
}

describe("with Cognito configured", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_COGNITO_REGION", "us-east-1")
    vi.stubEnv("VITE_COGNITO_USER_POOL_ID", POOL)
    vi.stubEnv("VITE_COGNITO_CLIENT_ID", "client-123")
    vi.stubEnv("VITE_COGNITO_DOMAIN", DOMAIN)
  })

  it("starts sign-in on /login/ by redirecting to Cognito", async () => {
    const redirect = vi.spyOn(UserManager.prototype, "signinRedirect").mockResolvedValue()
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/login/")
    await waitFor(() => expect(redirect).toHaveBeenCalledTimes(1))
    expect(screen.getByText(/Redirecting to the sign-in page/)).toBeInTheDocument()
  })

  it("shows an error and a retry when the redirect cannot start", async () => {
    vi.spyOn(UserManager.prototype, "signinRedirect").mockRejectedValue(new Error("offline"))
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/login/")
    expect(await screen.findByRole("alert")).toHaveTextContent("offline")
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument()
  })

  it("asks Cognito for the code flow with PKCE and the email scopes", () => {
    const settings = getUserManager().settings
    expect(settings.authority).toBe(`https://cognito-idp.us-east-1.amazonaws.com/${POOL}`)
    expect(settings.client_id).toBe("client-123")
    expect(settings.response_type).toBe("code")
    expect(settings.scope).toBe("openid email profile")
    expect(settings.client_secret).toBeUndefined()
    expect(settings.redirect_uri).toBe(`${window.location.origin}/auth/callback`)
  })

  it("sends the signed-in user's token to the API", async () => {
    await getUserManager().storeUser(cognitoUser())
    const fetchMock = mockFetch(() => ({ body: [] }))
    expect(await getApiToken()).toBe("id-token")

    await api.listMeetings()
    const call = fetchMock.mock.calls.find(([url]) => url === "/api/meetings")
    expect((call?.[1]?.headers as Record<string, string>).Authorization).toBe("Bearer id-token")
  })

  it("has no token when signed out", async () => {
    expect(await getApiToken()).toBeNull()
  })

  it("shows the email in the header of the calendar", async () => {
    await getUserManager().storeUser(cognitoUser())
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/home")
    expect(await screen.findByText("anna@example.com")).toBeInTheDocument()
  })

  it("signs out here and at Cognito's /logout", async () => {
    await getUserManager().storeUser(cognitoUser())
    const assign = vi.fn()
    vi.stubGlobal("location", { ...window.location, origin: window.location.origin, assign })
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/home")

    await userEvent.click(await screen.findByRole("button", { name: "Sign out" }))

    await waitFor(() => expect(assign).toHaveBeenCalledTimes(1))
    expect(await getUserManager().getUser()).toBeNull()
    const url = new URL(assign.mock.calls[0][0])
    expect(url.origin + url.pathname).toBe(`https://${DOMAIN}/logout`)
    expect(url.searchParams.get("client_id")).toBe("client-123")
    expect(url.searchParams.get("logout_uri")).toBe(`${window.location.origin}/`)
    expect(cognitoLogoutUrl()).toBe(url.toString())
  })

  it("rejects a callback this browser did not start", async () => {
    window.history.pushState({}, "", "/auth/callback?code=abc&state=forged")
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/auth/callback")
    expect(await screen.findByRole("alert")).toHaveTextContent("Sign-in failed")
    window.history.pushState({}, "", "/")
  })

  it("opens the calendar once the code is exchanged", async () => {
    window.history.pushState({}, "", "/auth/callback?code=abc&state=known")
    vi.spyOn(UserManager.prototype, "signinCallback").mockImplementation(async () => {
      const user = cognitoUser()
      await getUserManager().storeUser(user)
      return user
    })
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/auth/callback")
    expect(await screen.findByText("anna@example.com")).toBeInTheDocument()
    expect(window.location.search).toBe("")
    window.history.pushState({}, "", "/")
  })

  it("sends signed-out visitors of the calendar to /login/", async () => {
    const redirect = vi.spyOn(UserManager.prototype, "signinRedirect").mockResolvedValue()
    mockFetch(() => ({ body: [] }))
    renderWithQuery(<App />, "/home")
    await waitFor(() => expect(redirect).toHaveBeenCalledTimes(1))
  })
})

describe("front page with Cognito configured", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_COGNITO_REGION", "us-east-1")
    vi.stubEnv("VITE_COGNITO_USER_POOL_ID", POOL)
    vi.stubEnv("VITE_COGNITO_CLIENT_ID", "client-123")
    vi.stubEnv("VITE_COGNITO_DOMAIN", DOMAIN)
  })

  it("offers Sign in, Create account and Continue with Google", async () => {
    renderFrontPage()
    expect(await screen.findByRole("button", { name: "Create account" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Continue with Google/ })).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "Sign in" })).toHaveLength(2)
    // Cognito shows the forms; this page has none.
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument()
  })

  it("Sign in leads to /login/, which redirects to Cognito", async () => {
    const redirect = vi.spyOn(UserManager.prototype, "signinRedirect").mockResolvedValue()
    renderFrontPage()
    const links = await screen.findAllByRole("link", { name: "Sign in" })
    links.forEach((link) => expect(link).toHaveAttribute("href", "/login/"))
    await userEvent.click(links[links.length - 1])
    await waitFor(() => expect(redirect).toHaveBeenCalledTimes(1))
    // Plain sign-in: no identity_provider, so Cognito shows its own page with both options.
    expect(redirect.mock.calls[0][0]?.extraQueryParams).toBeUndefined()
  })

  it("Continue with Google goes straight to Google through Cognito", async () => {
    const redirect = vi.spyOn(UserManager.prototype, "signinRedirect").mockResolvedValue()
    renderFrontPage()
    await userEvent.click(await screen.findByRole("button", { name: /Continue with Google/ }))
    await waitFor(() => expect(redirect).toHaveBeenCalledTimes(1))
    expect(redirect).toHaveBeenCalledWith({ extraQueryParams: { identity_provider: "Google" } })
  })

  it("Create account opens Cognito's /signup with the same state and PKCE as a sign-in", async () => {
    const assign = renderFrontPage()
    await userEvent.click(await screen.findByRole("button", { name: "Create account" }))
    await waitFor(() => expect(assign).toHaveBeenCalledTimes(1))

    const url = new URL(assign.mock.calls[0][0])
    expect(url.origin + url.pathname).toBe(`https://${DOMAIN}/signup`)
    expect(url.searchParams.get("client_id")).toBe("client-123")
    expect(url.searchParams.get("redirect_uri")).toBe(`${window.location.origin}/auth/callback`)
    expect(url.searchParams.get("response_type")).toBe("code")
    expect(url.searchParams.get("scope")).toBe("openid email profile")
    expect(url.searchParams.get("code_challenge_method")).toBe("S256")
    const state = url.searchParams.get("state")
    expect(state).toBeTruthy()
    expect(url.searchParams.get("code_challenge")).toBeTruthy()
    // No identity_provider: the sign-up page offers its own options.
    expect(url.searchParams.has("identity_provider")).toBe(false)

    // The same request was saved in this browser, so /auth/callback accepts the code that returns.
    const { state: saved } = await getUserManager()
      .settings.stateStore.get(state!)
      .then((raw) => ({
        state: JSON.parse(raw!) as { id: string; code_verifier: string },
      }))
    expect(saved.id).toBe(state)
    expect(saved.code_verifier).toBeTruthy()
  })

  it("Create account has the same parameters as the /login/ redirect would", async () => {
    const assign = renderFrontPage()
    await userEvent.click(await screen.findByRole("button", { name: "Create account" }))
    await waitFor(() => expect(assign).toHaveBeenCalledTimes(1))
    const signup = new URL(assign.mock.calls[0][0])

    const request = await getUserManager().createSigninRequest()
    const authorize = new URL(request.url)
    expect(authorize.pathname).toBe("/oauth2/authorize")
    for (const name of [
      "client_id",
      "redirect_uri",
      "response_type",
      "scope",
      "code_challenge_method",
    ]) {
      expect(signup.searchParams.get(name)).toBe(authorize.searchParams.get(name))
    }
    // state and code_challenge are random per request, so they differ between the two requests.
    expect(signup.searchParams.get("state")).not.toBe(authorize.searchParams.get("state"))
  })

  it("shows an error, and does not leave, when Cognito's metadata cannot be fetched", async () => {
    // Another client id gives a fresh OIDC client, so metadata cached by earlier tests is not used.
    vi.stubEnv("VITE_COGNITO_CLIENT_ID", "client-no-metadata")
    const assign = vi.fn()
    vi.stubGlobal("location", { ...window.location, origin: window.location.origin, assign })
    mockFetch((url) =>
      url.endsWith("openid-configuration") ? { status: 500, body: {} } : { body: [] },
    )
    renderWithQuery(<App />, "/")
    await userEvent.click(await screen.findByRole("button", { name: "Create account" }))
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not reach the sign-in page")
    expect(assign).not.toHaveBeenCalled()
  })

  it("redirects a signed-in user from the front page to the calendar", async () => {
    await getUserManager().storeUser(cognitoUser())
    mockCognitoFetch()
    renderWithQuery(<App />, "/")
    expect(await screen.findByText("anna@example.com")).toBeInTheDocument()
    expect(await screen.findByRole("group", { name: "Calendar view" })).toBeInTheDocument()
  })
})

describe("toSignupUrl", () => {
  it("swaps only the path of the authorize URL", () => {
    expect(toSignupUrl("https://x.auth.us-east-1.amazoncognito.com/oauth2/authorize?a=1&b=2")).toBe(
      "https://x.auth.us-east-1.amazoncognito.com/signup?a=1&b=2",
    )
  })

  it("refuses an endpoint it does not know", () => {
    expect(() => toSignupUrl("https://x.example.com/somewhere?a=1")).toThrow()
  })
})
