# Decisions

## Monorepo
Backend, frontend, infrastructure and CI live in one repository. One commit can change an API and the code that calls it, and the whole system is in one place, so it is easy to read and change.

## Deployment on AWS
- Frontend: static files in a private S3 bucket, served through CloudFront over HTTPS.
- Backend: FastAPI in a Lambda container image with a function URL, plus Aurora Serverless PostgreSQL. It costs almost nothing when idle.
- Login: Amazon Cognito managed login (Essentials tier, free up to 10,000 monthly users), one sign-in page for email + password and Google. The user pool is code in `infra/cognito.yaml`.
- Everything is deployed with `make aws-deploy` and described in `infra/` (CloudFormation). The backend image is tagged with the commit SHA.
- Default AWS domains are used. The lecturer confirmed a custom domain is not required.
- AWS access keys are only in `.env`, which is git-ignored.

## Local run
`make start` runs Postgres, the backend and the frontend with Docker Compose. Migrations (Alembic) run when the backend container starts.

## Sign-in
- The frontend uses an OIDC library (`react-oidc-context`) with the authorization code flow and PKCE, not hand-written redirects. The app client is public: a browser cannot keep a secret, and PKCE protects the code exchange instead.
- Login starts at `/login/` in our own app, so the library's `state` and PKCE verifier exist when Cognito redirects back.
- Self sign-up stays on. Google's OAuth client is published ("In production"), so any Google account can sign in.
- Sign-out also visits Cognito's `/logout`; clearing only the local session would let Cognito's cookie sign the user straight back in.
- The Google client secret is only in `.env` and CloudFormation (`NoEcho`), never in the repository or the frontend build.
