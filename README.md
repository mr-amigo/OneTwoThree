# Meetings App

Monorepo with a FastAPI backend (`back/`), a React + shadcn/ui frontend (`front/`) and PostgreSQL,
all started with Docker Compose. See meetings in a week or day calendar, add them (title, time,
description, participants, call link, place), edit and remove them.

## Run everything

```bash
make up          # = cp .env.example .env (first time) + docker compose up --build --wait, then
                 #   docker compose watch: rebuilds backend/frontend when their files change
make start       # the same without watching (returns once the stack is healthy)
make help        # all targets: logs, test, lint, format, clean, aws-*
```

- App: http://localhost:3000 (front page with a Sign in button; the calendar is at `/home`). Until
  Cognito is set up (see [Sign-in](#sign-in-cognito)), nothing is checked: `/login/` offers to
  continue as one local user.
- API docs: http://localhost:3000/api/docs (or http://localhost:8000/api/docs directly)

If a host port is already taken, change `DB_PORT`, `BACKEND_PORT` or `FRONTEND_PORT` in `.env`.
`SEED=true` inserts 5 sample participants on first start. `docker compose down -v` wipes the database.

## Layout

```
compose.yaml      # db, backend, frontend
back/             # FastAPI + SQLAlchemy 2 + Alembic
  app/
    main.py       # app, CORS, error handlers
    lambda_handler.py # AWS Lambda entry point (Mangum) + migrate action
    reports/      # Weekly CSV report builder (weekly.py) and its Lambda handler (lambda_handler.py)
    ai/           # Agenda parser (agenda.py) over one LLM interface (llm.py: OpenAI Responses API, Claude on
                  # Bedrock via Messages or Converse), its Lambda handler (agenda_lambda.py), bedrock_check.py,
                  # prices (pricing.py) and the laptop CLI (cli.py: `make llm-hello`, `make parse`)
    models.py     # User, Meeting (owner_id → users), Participant, meeting_participants
    auth.py       # Cognito ID-token verification, current user
    schemas.py    # Pydantic request/response models
    services/     # business logic
    routers/      # /api/meetings, /api/participants, /api/health
  alembic/        # migrations (run on container start; on AWS via `make aws-backend-migrate`)
  Dockerfile.lambda # AWS Lambda image
  tests/
front/            # Vite + React + TypeScript + Tailwind + shadcn/ui
  src/
    pages/        # LandingPage (/), LoginPage (/login/, redirects to Cognito's sign-in page),
                  # AuthCallbackPage (/auth/callback), HomePage (/home, the calendar; needs sign-in)
    components/   # MeetingsCalendar, MeetingFormDialog, DeleteMeetingDialog, ParticipantsMultiSelect,
                  # AgendaDialog (Paste an agenda → pre-filled form → Save)
    components/ui # generated shadcn components
    hooks/        # TanStack Query hooks
    lib/calendar.ts # date helpers and the overlap layout for the calendar
    lib/auth.ts   # OIDC client for Cognito (react-oidc-context + oidc-client-ts): code flow + PKCE, token for the API
    lib/api.ts    # typed fetch wrapper (VITE_API_URL = backend origin, empty = same origin)
    lib/parser.ts # calls the parser's function URL (VITE_PARSER_URL), with cancel and error messages
  nginx.conf      # serves the SPA, proxies /api to backend
infra/            # CloudFormation: cognito, backend-ecr, backend (Lambda + Aurora), frontend (S3 + CloudFront),
                  # reports, ai (agenda parser Lambda + function URL + $5 budget)
docs/adr/         # architecture decision records (0006: LLM agenda parsing)
docs/lab6-report.md, docs/lab6-runs/ # Lab 6 test table, answers, raw runs, CloudWatch lines, screen recording
```

## API

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/health` | Liveness + DB check (no sign-in needed) |
| GET | `/api/me` | The signed-in user (created on first request) |
| PATCH | `/api/me` | Update the user's `name` |
| GET | `/api/meetings` | List meetings with participants, by start time |
| GET | `/api/meetings/{id}` | One meeting |
| POST | `/api/meetings` | Create a meeting |
| PUT | `/api/meetings/{id}` | Replace a meeting (same body as POST) |
| DELETE | `/api/meetings/{id}` | Delete a meeting |
| PUT | `/api/meetings/{id}/agenda` | Save the agenda and action items, with the AI suggestion they started from (`ai_suggestion`) |
| GET | `/api/participants?q=` | List/search participants |
| POST | `/api/participants` | Create a participant (409 on duplicate email) |
| DELETE | `/api/participants/{id}` | Delete a participant |

Everything except `/api/health` needs `Authorization: Bearer <Cognito ID token>`. Meetings are
personal: each belongs to the user who created it (`owner_id`), and other users get 404 for it. The
participant directory is shared. All IDs are UUIDs. A meeting needs a title, `starts_at` and `ends_at` (ISO 8601 with a timezone, end after start)
and at least one of `call_link` or `place`.

## Sign-in (Cognito)

The site has no password form of its own. **`/login/`** starts an OpenID Connect sign-in
(authorization code + PKCE, through `react-oidc-context`) and sends the browser to Cognito's managed
login page, which offers both **email + password** (with sign-up and the emailed confirmation code)
and **Continue with Google**. Cognito talks to Google; Google never talks to this site, so for the
frontend a Google user and a password user look the same: both come back with Cognito tokens. The
browser returns to `/auth/callback`, the code is exchanged for tokens, and the header shows the
signed-in email. Sign out clears the local session and then visits Cognito's `/logout`, because
Cognito has no standard OIDC end-session endpoint and keeps its own cookie session.

The login has to start at `/login/`: the library saves a random `state` and the PKCE verifier in the
browser before redirecting, and a hand-copied Cognito URL would come back to a callback that has
neither, so the code would be rejected.

The API verifies the token's signature, issuer, audience and expiry against the pool's public keys
and stores the user in the `users` table (keyed by the token's `sub`), where extra profile data lives.
A password user and a Google user with the same email are two different users with two different `sub`s.

**1. Google OAuth client** (Google Cloud console, a project of your own):

1. OAuth consent screen: user type External, scopes only `openid`, `email`, `profile`, and
   **publish** the app (status "In production"; in "Testing" only listed test users can sign in).
2. Create an OAuth client ID of type "Web application" with
   - authorised JavaScript origin `https://<COGNITO_DOMAIN>`,
   - authorised redirect URI `https://<COGNITO_DOMAIN>/oauth2/idpresponse`,

   where `<COGNITO_DOMAIN>` is `meetings-<AWS account id>.auth.us-east-1.amazoncognito.com`
   (`make aws-check` prints the account id).
3. Put the client ID and secret in `.env` as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. The secret
   goes to CloudFormation as a `NoEcho` parameter and never appears in the repository or the frontend build.

**2. Deploy the user pool:**

```bash
make aws-cognito-deploy   # user pool (Essentials tier) + Google + app client + managed login; prints the lines for .env
make aws-cognito-env      # print them again
```

Paste the printed `COGNITO_*` lines into `.env` and run `make up`; the local frontend and backend
then use the real user pool (`http://localhost:3000/auth/callback` and `http://localhost:5173/auth/callback`
are registered). With `COGNITO_USER_POOL_ID` empty, auth is off: no token is checked and every
request acts as one local user (`dev@localhost`).

Callback URLs must match `redirect_uri` exactly, including a trailing slash. The app uses
`<origin>/auth/callback` without one. Cognito's built-in email sender allows about 50 messages a day;
a real product would send through Amazon SES.

On AWS the Lambda has no internet access, so `aws-backend-stack` downloads the pool's JWKS and passes
it in as `COGNITO_JWKS`. Cognito does not rotate user pool signing keys. Meetings created before
accounts existed have no owner, so nobody sees them.

## Local development

Backend (needs a Postgres, e.g. `docker compose up -d db`):

```bash
cd back
uv sync
DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings uv run alembic upgrade head
DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings uv run uvicorn app.main:app --reload
```

Frontend (Vite proxies `/api` to `http://localhost:8000`, override with `VITE_API_PROXY`):

```bash
cd front
npm install
npm run dev        # http://localhost:5173
```

## Tests

```bash
# backend: uses a separate database (created once)
docker compose exec db psql -U meetings -c "CREATE DATABASE meetings_test"
cd back && TEST_DATABASE_URL=postgresql+psycopg://meetings:meetings@localhost:5432/meetings_test uv run pytest

# frontend
cd front && npm test
```

## Code style

CI (`.github/workflows/code-style.yml`) runs on every push to `main` and on pull requests:

| Part | Tools | Run locally | Auto-fix |
| --- | --- | --- | --- |
| `back/` | Ruff (lint + format) | `uv run ruff check . && uv run ruff format --check .` | `uv run ruff check --fix . && uv run ruff format .` |
| `front/` | ESLint, Prettier, `tsc` | `npm run lint && npm run format:check && npm run typecheck` | `npm run format` |

Config lives in `back/pyproject.toml` (`[tool.ruff]`), `front/eslint.config.js` and `front/.prettierrc.json`.

## Lab 6: Paste an agenda (LLM)

On a meeting, **Agenda** opens a dialog. You paste an email, a chat message or notes and press **Parse**. The
agenda-parser Lambda (outside the VPC, behind a Cognito-protected function URL) asks an LLM to call one tool,
`record_agenda`, and validates the result against a Pydantic schema, retrying once with the error. The browser shows
the normal agenda form, pre-filled, with every model-filled field marked "suggested". **Save** goes through the normal
API (`PUT /api/meetings/{id}/agenda`), which stores the final agenda next to the model's suggestion (`ai_suggestion`:
agenda, model, prompt version). The model never writes anything.

**Provider.** The lab specifies Claude on Amazon Bedrock. That path is implemented (`PARSER_PROVIDER=bedrock`, Anthropic
Messages API; `bedrock-converse`, Converse API) and allowed by the function's IAM role, but this course account cannot
use it. AWS keeps every Claude inference quota of the account at 0 (the defaults are 5–30 million tokens a minute), and
AWS Support declined every increase for the whole account. Model access and the Marketplace agreements are in place.
With the lecturer's agreement, the deployed parser uses the OpenAI Responses API (`PARSER_PROVIDER=openai`,
`gpt-5.4-mini`) behind the same interface. Details: [ADR 0006](docs/adr/0006-llm-agenda-parsing.md) (amendment of
2026-11-24). The support correspondence was submitted to the lecturer separately, because it contains personal data.

```bash
make llm-hello                       # one call to the configured model: answer, stop_reason, tokens
make parse TEXT="Mon 10:00 pricing sync, 45 min. 1) Pro plans, Olena, 15 min"
make bedrock-check                   # can this account use Claude on Bedrock? access, quotas, one call per API
make aws-ai-logs                     # one JSON line per parse: provider, model, prompt version, tokens, latency, cost
make aws-ai-deploy PARSER_PROVIDER=bedrock PARSER_MODEL=anthropic.claude-opus-5-5   # switch once bedrock-check says READY
```

Results: [docs/lab6-report.md](docs/lab6-report.md) has the five-input test table for gpt-5.4-mini and gpt-5.4-nano,
CloudWatch log lines, cost per parse (≈ $0.00086) and the answers. [docs/lab6-runs/](docs/lab6-runs/) has the raw
responses, the CloudWatch export and a screen recording of the deployed app (`paste-an-agenda.mp4`).

## Deploy to AWS (backend on Lambda + Aurora Serverless, frontend on CloudFront)

Everything is deployed to **us-east-1**. CloudFront accepts custom-domain certificates only from that region. Infrastructure is CloudFormation in `infra/`:

- `infra/cognito.yaml`: Cognito user pool (Essentials tier, email + password, self sign-up with email code), Google identity provider, public app client (code flow, no secret), and a managed login (version 2) domain with its branding.
- `infra/backend-ecr.yaml`: ECR repository for the backend's Lambda container image (`back/Dockerfile.lambda`).
- `infra/backend.yaml`: VPC with private subnets, Aurora Serverless v2 PostgreSQL (scales to 0 ACU when idle), and a Lambda function with a public **function URL**, which is the backend URL.
- `infra/frontend.yaml`: private S3 bucket and CloudFront distribution for the SPA on the **flat-rate Free plan** ($0/month, with the WAF web ACL the plan requires), with an optional custom domain.
- `infra/ai.yml`: agenda parser Lambda (same image, handler `app.ai.agenda_lambda.handler`) **outside the VPC** with a public function URL (POST only, CORS for the site's origins). It verifies the Cognito ID token, rejects text over 10,000 characters, calls the LLM chosen by `PARSER_PROVIDER` (default `openai`: OpenAI Responses API with `OPENAI_API_KEY`; `bedrock`: Claude through the Messages API, `bedrock-mantle:CreateInference`; `bedrock-converse`: any Bedrock model through Converse, `bedrock:InvokeModel`) and logs one JSON line per parse, failed ones included. Also a $5/month AWS Budgets alarm.
- `infra/reports.yaml`: event-driven weekly report pipeline — EventBridge Scheduler (`cron(0 7 ? * MON *)` in `Europe/Kyiv`), SQS queue (`report-requests`) with a DLQ, Builder Lambda in the VPC writing `reports/<week>.csv` to S3 through a free S3 Gateway VPC Endpoint, and Mailer Lambda outside the VPC sending the CSV attachment via Amazon SES on `s3:ObjectCreated:*`.

Every resource carries the tag `PROJECT_NAME=<project>`. It is set in the templates and as a stack tag, and `cert.sh` puts it on the ACM certificate. Some resource types can't be tagged in AWS at all: function URLs, Lambda permissions, the bucket policy, the CloudFront origin access control, Route 53 records and the pricing plan subscription.

Containers (C4 level 2). The two Lab 6 paths: **parse** (browser → parser → LLM, returns JSON, writes nothing) and **save** (browser → API → Aurora, the normal validated endpoint).

```mermaid
flowchart LR
    B[Browser SPA] -->|HTTPS| CF[CloudFront + WAF<br/>Free plan, optional custom domain]
    CF --> S3[(S3<br/>built SPA)]
    B -->|"save: PUT /api/meetings/{id}/agenda<br/>agenda + ai_suggestion"| URL[API function URL]
    URL --> L[API Lambda<br/>FastAPI via Mangum<br/>private subnets]
    L -->|:5432| DB[(Aurora Serverless v2<br/>PostgreSQL, private subnets)]
    B -->|"parse: POST text, today, tz<br/>Cognito ID token"| PURL[Parser function URL]
    PURL --> P[agenda-parser Lambda<br/>outside the VPC, no DB]
    P -->|"HTTPS, record_agenda function call"| OAI[OpenAI API<br/>gpt-5.4-mini]
    P -.->|"PARSER_PROVIDER=bedrock<br/>(blocked on this account, see ADR 0006)"| BR[Claude on Amazon Bedrock<br/>bedrock-mantle, us-east-1]
    P -. one JSON log line per parse .-> CW[CloudWatch Logs]
    L -. image .-> ECR[ECR]
    P -. same image .-> ECR
```

1. Put credentials into `.env` (an IAM user or role allowed to use CloudFormation, EC2/VPC, Lambda, ECR, RDS, Secrets Manager, S3, CloudFront, WAF, Pricing Plan Manager, ACM, Route 53, IAM and CloudWatch Logs):

   ```
   AWS_ACCESS_KEY_ID=...
   AWS_SECRET_ACCESS_KEY=...
   ```

2. Optionally copy `infra/backend.params.example.env` to `infra/backend.params.env` to override stack parameters (memory, Aurora capacity, seeding, …).
3. Deploy. The first run takes about 15 minutes, mostly waiting for Aurora and CloudFront:

   ```bash
   make aws-deploy   # = aws-cognito-deploy, aws-backend-deploy, aws-ai-deploy, then aws-frontend-deploy
   ```

   The steps run in this order:

   1. **Cognito** (`make aws-cognito-deploy`): user pool, Google provider, app client and managed login domain. Needs `GOOGLE_CLIENT_ID/SECRET` in `.env`. Redirect URLs cover localhost and the site's origins. It prints the `.env` lines for local use.
   2. **Backend** (`make aws-backend-deploy`): ECR stack → build and push the Lambda image → backend stack → `aws-backend-migrate` invokes the function with `{"action": "migrate"}` to run Alembic and seeding. It prints the function URL (`https://<id>.lambda-url.us-east-1.on.aws/`).
   3. **Agenda parser** (`make aws-ai-deploy`): pushes the image and deploys `infra/ai.yml` with `PARSER_PROVIDER`/`PARSER_MODEL` (default `openai`/`gpt-5.4-mini`, needs `OPENAI_API_KEY` in `.env`) and the $5 budget alarm to `BUDGET_ALERT_EMAIL` (or `REPORT_EMAIL`). For Claude on Bedrock: `make bedrock-check` (model access, quotas, one call per Bedrock API → READY/BLOCKED), then `make aws-ai-deploy PARSER_PROVIDER=bedrock PARSER_MODEL=anthropic.claude-opus-5-5`. The same overrides work for `make llm-hello` and `make parse`. `make aws-ai-logs` shows the per-parse log lines; `make llm-hello` and `make parse TEXT="..."` try the model from a laptop.
   4. **Frontend** (`make aws-frontend-deploy`): frontend stack → `npm run build` with `VITE_API_URL=<function URL>` and the `VITE_COGNITO_*` IDs → upload to S3 and invalidate CloudFront → allow the site's origin in the backend's `CORS_ORIGINS` and as a Cognito redirect URL. It prints the site URL.

Other targets: `make aws-backend-outputs`, `aws-backend-status`, `aws-backend-logs`, `aws-backend-health`, `aws-backend-migrate`, `aws-frontend-outputs`, `aws-frontend-publish` (rebuild and upload the frontend only), `aws-destroy`. Use `ARCH=amd64` to build an x86 Lambda instead of Graviton (`arm64`, the default). Use `CLOUDFRONT_PLAN=PAY_AS_YOU_GO` if the account can't subscribe to the Free plan (accounts on the AWS Free Tier are not eligible, and each account gets at most 3 free plans).

### Custom domain for the frontend (optional)

By default the site is served on its `*.cloudfront.net` domain. To add a custom domain (default `onetwothree.dobosevych.com`, override with `FRONTEND_DOMAIN=app.example.com`), deploy once and then run:

```bash
make aws-frontend-cert        # 1. request the ACM certificate (free, us-east-1) and set up DNS validation
make aws-frontend-https       # 2. wait until it is issued, attach it to CloudFront, allow it in CORS, set up DNS
make aws-frontend-https-check # 3. curl https://onetwothree.dobosevych.com/
```

- **Domain's zone in Route 53 (same account):** the zone is found automatically. The validation record and alias `A`/`AAAA` records to CloudFront are created for you.
- **Any other DNS provider:** step 1 prints a validation `CNAME` to add there. Step 2 prints the `CNAME <domain> → <id>.cloudfront.net` record to add.

`make aws-frontend-cert-status` and `make aws-frontend-dns` show the records again. Once the certificate is issued, every later `make aws-deploy` keeps the domain. The backend stays on its function URL.

**Cost.** There is no load balancer, NAT gateway or public IPv4 address. Lambda and function URLs fit in the always-free tier for a small app. CloudFront runs on the flat-rate Free plan, which costs $0 with no overage charges and also covers its WAF web ACL (a per-IP rate limit). Requests that WAF blocks don't count toward the plan's allowance. Aurora Serverless v2 has no free tier. With `DbMinCapacity=0` it pauses after 5 idle minutes, and then you pay only for storage (about $0.10/GB-month). While active it costs about $0.12 per ACU-hour. The first request after a pause waits about 15 seconds while Aurora resumes. The DB credentials secret costs $0.40/month. Run `make aws-destroy` when you are done. It keeps a final Aurora snapshot.

On AWS the backend reads `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` and `DB_PASSWORD` instead of `DATABASE_URL`. The password is generated in Secrets Manager and resolved into the function's environment at deploy time, so the VPC needs no internet access. `DB_NULL_POOL=true` closes connections after each request, because idle connections from warm Lambdas would stop Aurora from pausing. Migrations do not run on cold start. `make aws-backend-migrate` runs them, and every `aws-backend-deploy` calls it.
