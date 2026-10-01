# Decisions

## Monorepo
Backend, frontend, infrastructure and CI live in one repository. One commit can change an API and the code that calls it, and the whole system is in one place, so it is easy to read and change.

## Deployment on AWS
- Frontend: static files in a private S3 bucket, served through CloudFront over HTTPS.
- Backend: FastAPI in a Lambda container image with a function URL, plus Aurora Serverless PostgreSQL. It costs almost nothing when idle.
- Login: Amazon Cognito (email + password).
- Everything is deployed with `make aws-deploy` and described in `infra/` (CloudFormation). The backend image is tagged with the commit SHA.
- Default AWS domains are used. The lecturer confirmed a custom domain is not required.
- AWS access keys are only in `.env`, which is git-ignored.

## Local run
`make start` runs Postgres, the backend and the frontend with Docker Compose. Migrations (Alembic) run when the backend container starts.
