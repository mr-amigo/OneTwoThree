import { Navigate, Route, Routes } from "react-router"

import { RequireAuth } from "@/components/auth/RequireAuth"
import { SessionProvider } from "@/components/auth/SessionProvider"
import { AuthCallbackPage } from "@/pages/AuthCallbackPage"
import { HomePage } from "@/pages/HomePage"
import { LandingPage } from "@/pages/LandingPage"
import { LoginPage } from "@/pages/LoginPage"

export default function App() {
  return (
    <SessionProvider>
      <Routes>
        <Route path="/" element={<LandingPage />} />
        <Route path="/login" element={<LoginPage />} />
        <Route path="/auth/callback" element={<AuthCallbackPage />} />
        <Route
          path="/home"
          element={
            <RequireAuth>
              <HomePage />
            </RequireAuth>
          }
        />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </SessionProvider>
  )
}
