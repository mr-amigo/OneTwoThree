import { screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { describe, expect, it } from "vitest"

import App from "@/App"
import { mockFetch, renderWithQuery, signInForTest } from "@/test/utils"

function renderAt(route: string) {
  mockFetch(() => ({ body: [] }))
  renderWithQuery(<App />, route)
}

const calendarShown = () => screen.findByRole("group", { name: "Calendar view" }, { timeout: 2000 })

// Without VITE_COGNITO_* the app runs with auth off (local development).
describe("Front page and sign-in with auth off", () => {
  it("has Sign in in the header and on the page, both pointing to /login/", () => {
    renderAt("/")
    const links = screen.getAllByRole("link", { name: /Sign in/ })
    expect(links).toHaveLength(2)
    links.forEach((link) => expect(link).toHaveAttribute("href", "/login/"))
    expect(screen.queryByRole("button", { name: "Sign out" })).not.toBeInTheDocument()
  })

  it("shows the sign-in page layout, without Cognito-only buttons", () => {
    renderAt("/")
    expect(screen.getByRole("heading", { name: "Sign in" })).toBeInTheDocument()
    expect(
      screen.getByText("Plan meetings, invite people and know where to be."),
    ).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Create account" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Continue with Google/ })).not.toBeInTheDocument()
  })

  it("sends a signed-in user from the front page to the calendar", async () => {
    signInForTest()
    renderAt("/")
    expect(await calendarShown()).toBeInTheDocument()
  })

  it("sends signed-out users from the calendar to /login/", async () => {
    renderAt("/home")
    expect(await screen.findByRole("heading", { name: "Sign in" })).toBeInTheDocument()
  })

  it("opens the calendar after continuing as the local user", async () => {
    renderAt("/login/")
    await userEvent.click(screen.getByRole("button", { name: "Continue as local developer" }))
    expect(await calendarShown()).toBeInTheDocument()
  })

  it("has no sign-up or password form of its own: that is Cognito's page", () => {
    renderAt("/login/")
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Sign up" })).not.toBeInTheDocument()
  })
})
