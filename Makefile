# Meetings App — local Docker Compose workflow and AWS deployment.
# Infrastructure: Terraform in infra/ (Cognito, weekly report, agenda parser; applied only by GitHub Actions,
# see .github/workflows/infra.yml) and CloudFormation for the older stacks (network + API + Aurora, ECR, site).
# Run `make` or `make help` to list targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# .env holds compose settings and AWS credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# optionally AWS_SESSION_TOKEN). Only the keys defined in .env are exported.
-include .env
export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env 2>/dev/null)

# ---------------------------------------------------------------------------
# Settings (override on the command line, e.g. `make aws-deploy ARCH=amd64`)
# ---------------------------------------------------------------------------
PROJECT     ?= meetings
# Everything is deployed to us-east-1: CloudFront takes custom-domain certificates only from there.
# (Set here, not in .env; `make … AWS_REGION=…` still overrides it for the backend.)
AWS_REGION  := us-east-1
export AWS_REGION
export AWS_DEFAULT_REGION := $(AWS_REGION)

# arm64 (Graviton, cheaper; native on Apple Silicon) or amd64
ARCH        ?= arm64
# Lambda only picks up a new image when its URI changes, so uncommitted builds get a unique tag.
ifndef TAG
TAG         := $(shell git describe --always --dirty=-dirty-$$(date +%Y%m%d%H%M%S) 2>/dev/null || date +%Y%m%d%H%M%S)
endif

BACKEND_ECR_STACK := $(PROJECT)-backend-ecr
BACKEND_STACK     := $(PROJECT)-backend
BACKEND_FUNCTION  := $(PROJECT)-backend
BACKEND_PARAMS    := infra/backend.params.env
FRONTEND_STACK    := $(PROJECT)-frontend
REPORT_BUILDER_FUNCTION := $(PROJECT)-report-builder
REPORT_MAILER_FUNCTION  := $(PROJECT)-report-mailer
REPORT_SCHEDULE_EXPRESSION ?= cron(0 7 ? * MON *)
REPORT_SCHEDULE_TIMEZONE   ?= Europe/Kyiv
REPORT_SCHEDULE_TARGET     ?= SQS
REPORT_SENDER_EMAIL        ?= $(REPORT_EMAIL)
REPORT_RECIPIENT_EMAIL     ?= $(or $(REPORT_EMAIL),$(REPORT_SENDER_EMAIL))
# Every resource gets this tag (in the templates and as a stack tag).
STACK_TAGS        := PROJECT_NAME=$(PROJECT)

# CloudFront flat-rate Free plan ($0/month); PAY_AS_YOU_GO if the account can't subscribe (AWS Free Tier
# accounts, or 3 free plans already in use).
CLOUDFRONT_PLAN   ?= FREE

# Optional custom domain for the frontend (`make aws-frontend-https`); empty = CloudFront domain only.
FRONTEND_DOMAIN   ?= onetwothree.dobosevych.com
CERT_SH           := PROJECT_NAME=$(PROJECT) infra/scripts/cert.sh
# Browser origins the API always allows besides the frontend's (local development).
CORS_LOCAL        ?= http://localhost:3000,http://localhost:5173

LAMBDA_ARCH  = $(if $(filter arm64,$(ARCH)),arm64,x86_64)
HASH        := \#
COMMA       := ,
# $(shell) does not inherit exported variables in GNU make < 4.4 (macOS ships 3.81),
# so AWS lookups inside $(shell) load .env themselves.
LOAD_ENV    := set -a; [ -f .env ] && . ./.env; set +a; export AWS_REGION=$(AWS_REGION) AWS_DEFAULT_REGION=$(AWS_REGION);
AWS_SHELL   := $(LOAD_ENV) aws
# Recursive (=) so they are looked up only when a recipe needs them, after the stacks exist.
stack_output = $(shell $(AWS_SHELL) cloudformation describe-stacks --stack-name $(1) \
                 --query "Stacks[0].Outputs[?OutputKey=='$(2)'].OutputValue" --output text 2>/dev/null)
ECR_URI      = $(call stack_output,$(BACKEND_ECR_STACK),RepositoryUri)
ECR_REGISTRY = $(firstword $(subst /, ,$(ECR_URI)))
BACKEND_PARAMS_ARGS = $(shell [ -f $(BACKEND_PARAMS) ] && grep -v -e '^[[:space:]]*$(HASH)' -e '^[[:space:]]*$$' $(BACKEND_PARAMS))
backend_output  = $(call stack_output,$(BACKEND_STACK),$(1))
frontend_output = $(call stack_output,$(FRONTEND_STACK),$(1))
# Outputs of the Terraform configuration in infra/ (state in S3; `make infra-init` once per checkout).
tf_output       = $(shell $(LOAD_ENV) terraform -chdir=infra output -raw $(1) 2>/dev/null)
API_URL          = $(call backend_output,ApiUrl)
FRONTEND_ORIGINS = $(call frontend_output,SiteOrigins)
CORS_ORIGINS_AWS = $(CORS_LOCAL)$(if $(FRONTEND_ORIGINS),$(COMMA)$(FRONTEND_ORIGINS))
# Cognito may redirect back (Google sign-in) to every origin the API allows.
COGNITO_CALLBACK_URLS = $(subst $(COMMA),/auth/callback$(COMMA),$(CORS_ORIGINS_AWS))/auth/callback
COGNITO_LOGOUT_URLS   = $(subst $(COMMA),/$(COMMA),$(CORS_ORIGINS_AWS))/
COGNITO_POOL_ID   = $(call tf_output,user_pool_id)
COGNITO_CLIENT    = $(call tf_output,user_pool_client_id)
COGNITO_ISSUER    = $(call tf_output,cognito_issuer)
COGNITO_DOMAIN    = $(call tf_output,cognito_domain)
FRONTEND_CERT_ARN = $(if $(FRONTEND_DOMAIN),$(shell $(LOAD_ENV) $(CERT_SH) arn $(FRONTEND_DOMAIN) 2>/dev/null))
FRONTEND_ZONE_ID  = $(shell $(LOAD_ENV) $(CERT_SH) zone-id $(FRONTEND_DOMAIN) 2>/dev/null)
# The custom domain is attached once its certificate is issued; until then only the CloudFront domain serves.
FRONTEND_DOMAIN_ARGS = $(if $(FRONTEND_CERT_ARN),CertificateArn=$(FRONTEND_CERT_ARN) DomainName=$(FRONTEND_DOMAIN) HostedZoneId=$(FRONTEND_ZONE_ID))

# A stack whose first create failed is left in ROLLBACK_COMPLETE (holding no resources) and can't be
# updated; delete it so the next deploy creates it again.
define clear_failed_stack
	@if [ "$$(aws cloudformation describe-stacks --stack-name $(1) --query 'Stacks[0].StackStatus' --output text 2>/dev/null)" = ROLLBACK_COMPLETE ]; then \
	  echo "Stack $(1) is in ROLLBACK_COMPLETE after a failed create; deleting it before deploying again"; \
	  aws cloudformation delete-stack --stack-name $(1) && aws cloudformation wait stack-delete-complete --stack-name $(1); \
	fi
endef

TEST_DB_URL := postgresql+psycopg://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(or $(DB_PORT),5432)/meetings_test

##@ Local (Docker Compose)

.env:
	cp .env.example .env
	@echo "Created .env from .env.example — review it (ports, AWS credentials)."

.PHONY: up
up: start ## Start the stack, then rebuild backend/frontend whenever their files change (Ctrl+C stops watching)
	@echo "Watching back/ and front/ for changes — Ctrl+C stops watching, containers keep running."
	docker compose watch --no-up

.PHONY: start
start: .env ## Build and start db, backend and frontend in the background, without watching
	docker compose up -d --build --wait
	@echo "App: http://localhost:$(or $(FRONTEND_PORT),3000)   API docs: http://localhost:$(or $(FRONTEND_PORT),3000)/api/docs"

.PHONY: down
down: ## Stop all containers (data is kept)
	docker compose down

.PHONY: clean
clean: ## Stop containers and delete the database volume
	docker compose down -v --remove-orphans

.PHONY: restart
restart: down start ## Restart the stack

.PHONY: logs
logs: ## Follow logs of all services (SERVICE=backend to narrow)
	docker compose logs -f $(SERVICE)

.PHONY: ps
ps: ## Show container status
	docker compose ps

##@ Quality

.PHONY: test
test: test-back test-front ## Run all tests

.PHONY: test-back
test-back: .env ## Backend tests (starts the db container, creates meetings_test)
	docker compose up -d --wait db
	docker compose exec -T db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -tAc \
	  "SELECT 1 FROM pg_database WHERE datname = 'meetings_test'" | grep -q 1 || \
	  docker compose exec -T db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -c "CREATE DATABASE meetings_test"
	cd back && COGNITO_USER_POOL_ID= TEST_DATABASE_URL=$(TEST_DB_URL) uv run pytest -q

.PHONY: test-front
test-front: ## Frontend tests
	cd front && npm test

.PHONY: lint
lint: ## Code style checks (same as CI)
	cd back && uv run ruff check . && uv run ruff format --check .
	cd front && npm run lint && npm run format:check && npm run typecheck
	uvx cfn-lint infra/*.y*ml
	terraform -chdir=infra fmt -check -recursive

.PHONY: format
format: ## Auto-format backend and frontend
	cd back && uv run ruff check --fix . && uv run ruff format .
	cd front && npm run format

##@ AWS backend (Lambda + Aurora Serverless v2 via CloudFormation)

.PHONY: aws-check
aws-check: ## Verify AWS credentials from .env work
	@aws sts get-caller-identity --query '[Account, Arn]' --output text \
	  || { echo "AWS credentials missing/invalid: set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in .env"; exit 1; }

.PHONY: aws-backend-deploy
aws-backend-deploy: aws-check aws-backend-ecr aws-backend-push aws-backend-stack aws-backend-migrate ## Deploy backend: ECR, image, Aurora, Lambda + function URL, migrations
	@echo
	@echo "API:      $(API_URL)"
	@echo "API docs: $(call backend_output,ApiDocsUrl)"

.PHONY: aws-backend-ecr
aws-backend-ecr: ## Create/update the ECR repository stack
	$(call clear_failed_stack,$(BACKEND_ECR_STACK))
	aws cloudformation deploy --stack-name $(BACKEND_ECR_STACK) --template-file infra/backend-ecr.yaml \
	  --parameter-overrides ProjectName=$(PROJECT) --tags $(STACK_TAGS) --no-fail-on-empty-changeset

.PHONY: aws-backend-login
aws-backend-login: ## Log Docker in to ECR
	@test -n "$(ECR_URI)" || { echo "ECR repository not found: run \`make aws-backend-ecr\` first (and check AWS credentials in .env)"; exit 1; }
	aws ecr get-login-password | docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: aws-backend-push
aws-backend-push: aws-backend-login ## Build the Lambda image for linux/$(ARCH) and push it with tag $(TAG)
	docker buildx build --platform linux/$(ARCH) --provenance=false -f back/Dockerfile.lambda \
	  -t $(ECR_URI):$(TAG) -t $(ECR_URI):latest --push back

.PHONY: aws-backend-stack
aws-backend-stack: ## Create/update the backend stack (VPC, Aurora, Lambda) with image tag $(TAG); KEEP_IMAGE=1 keeps the current image
	$(call clear_failed_stack,$(BACKEND_STACK))
	@test -n "$(ECR_URI)" || { echo "ECR repository not found: run \`make aws-backend-ecr\` first (and check AWS credentials in .env)"; exit 1; }
	@test -n "$(COGNITO_POOL_ID)" || { echo "Cognito not deployed: apply infra/ first (README: Infrastructure as code)"; exit 1; }
	@# The function has no internet route, so the pool's signing keys are passed in with the stack.
	jwks=$$(curl -fsS "$(COGNITO_ISSUER)/.well-known/jwks.json") && \
	aws cloudformation deploy --stack-name $(BACKEND_STACK) --template-file infra/backend.yaml \
	  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags $(STACK_TAGS) \
	  --parameter-overrides ProjectName=$(PROJECT) $(if $(KEEP_IMAGE),,ImageUri=$(ECR_URI):$(TAG)) \
	    Architecture=$(LAMBDA_ARCH) "CorsOrigins=$(CORS_ORIGINS_AWS)" \
	    CognitoUserPoolId=$(COGNITO_POOL_ID) CognitoClientId=$(COGNITO_CLIENT) "CognitoJwks=$$jwks" \
	    $(BACKEND_PARAMS_ARGS)

.PHONY: aws-backend-migrate
aws-backend-migrate: ## Run Alembic migrations (and seeding) inside the Lambda
	@resp=$$(mktemp); \
	err=$$(aws lambda invoke --function-name $(BACKEND_FUNCTION) --cli-binary-format raw-in-base64-out \
	  --payload '{"action": "migrate"}' --cli-read-timeout 0 --query FunctionError --output text "$$resp"); \
	echo "Migrations: $$(cat "$$resp")"; rm -f "$$resp"; \
	[ "$$err" = None ] || { echo "Migration failed ($$err): make aws-backend-logs"; exit 1; }

.PHONY: aws-backend-outputs
aws-backend-outputs: ## Show backend stack outputs (API URL, DB endpoint, ...)
	@aws cloudformation describe-stacks --stack-name $(BACKEND_STACK) \
	  --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" --output table

.PHONY: aws-backend-status
aws-backend-status: ## Show Lambda and Aurora status
	@aws lambda get-function-configuration --function-name $(BACKEND_FUNCTION) \
	  --query "{state:State, lastUpdate:LastUpdateStatus, image:CodeSha256, memory:MemorySize, timeout:Timeout}" --output yaml
	@aws rds describe-db-clusters --db-cluster-identifier $(PROJECT)-db \
	  --query "DBClusters[0].{status:Status, capacity:ServerlessV2ScalingConfiguration}" --output yaml

.PHONY: aws-backend-logs
aws-backend-logs: ## Tail backend logs from CloudWatch
	aws logs tail /aws/lambda/$(BACKEND_FUNCTION) --follow --since 30m

.PHONY: aws-backend-health
aws-backend-health: ## Call /api/health on the function URL (the first call after a pause wakes Aurora, ~15 s)
	curl -fsS --max-time 60 $(API_URL)api/health && echo

.PHONY: aws-backend-destroy
aws-backend-destroy: aws-check ## Delete backend stacks (a final Aurora snapshot is kept)
	@read -p "Delete stacks $(BACKEND_STACK) and $(BACKEND_ECR_STACK) in $(AWS_REGION)? [y/N] " ok && [ "$$ok" = y ]
	aws cloudformation delete-stack --stack-name $(BACKEND_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_STACK)
	aws cloudformation delete-stack --stack-name $(BACKEND_ECR_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(BACKEND_ECR_STACK)
	@echo "Done. Remove the final snapshot with: aws rds describe-db-cluster-snapshots --snapshot-type manual"

##@ AWS frontend (S3 + CloudFront on the flat-rate Free plan, built with the backend URL)

.PHONY: aws-frontend-deploy
aws-frontend-deploy: aws-check aws-frontend-stack aws-frontend-publish aws-frontend-cors ## Deploy frontend: stack, build with the API URL, upload, allow its origin in the API and Cognito
	@echo
	@echo "Site: $(call frontend_output,SiteUrl)"

.PHONY: aws-frontend-stack
aws-frontend-stack: ## Create/update the frontend stack (S3, CloudFront + WAF on the Free plan, custom domain once its certificate is issued)
	$(call clear_failed_stack,$(FRONTEND_STACK))
	aws cloudformation deploy --stack-name $(FRONTEND_STACK) --template-file infra/frontend.yaml \
	  --no-fail-on-empty-changeset --tags $(STACK_TAGS) \
	  --parameter-overrides ProjectName=$(PROJECT) PricingPlan=$(CLOUDFRONT_PLAN) \
	    $(or $(FRONTEND_DOMAIN_ARGS),CertificateArn= DomainName= HostedZoneId=)

.PHONY: aws-frontend-publish
aws-frontend-publish: ## Build the SPA with VITE_API_URL=<function URL>, upload it, invalidate CloudFront
	@api="$(API_URL)"; bucket="$(call frontend_output,BucketName)"; dist="$(call frontend_output,DistributionId)"; \
	[ -n "$$api" ] || { echo "Backend not deployed: run \`make aws-backend-deploy\` first"; exit 1; }; \
	[ -n "$$bucket" ] || { echo "Frontend stack not found: run \`make aws-frontend-stack\` first"; exit 1; }; \
	[ -n "$(COGNITO_POOL_ID)" ] || { echo "Cognito not deployed: apply infra/ first (README: Infrastructure as code)"; exit 1; }; \
	echo "Building frontend with VITE_API_URL=$$api" && \
	(cd front && npm ci --no-audit --no-fund && VITE_API_URL="$$api" \
	  VITE_PARSER_URL="$(PARSER_URL)" \
	  VITE_COGNITO_REGION=$(AWS_REGION) VITE_COGNITO_USER_POOL_ID=$(COGNITO_POOL_ID) \
	  VITE_COGNITO_CLIENT_ID=$(COGNITO_CLIENT) VITE_COGNITO_DOMAIN=$(COGNITO_DOMAIN) \
	  npm run build) && \
	aws s3 sync front/dist "s3://$$bucket" --delete --exclude index.html \
	  --cache-control "public,max-age=31536000,immutable" && \
	aws s3 cp front/dist/index.html "s3://$$bucket/index.html" --cache-control "no-cache" && \
	aws cloudfront create-invalidation --distribution-id "$$dist" --paths "/*" \
	  --query "Invalidation.Status" --output text

.PHONY: aws-frontend-cors
aws-frontend-cors: ## Allow the frontend's origins in the backend's CORS settings (keeps the current image)
	@$(MAKE) --no-print-directory aws-backend-stack KEEP_IMAGE=1
	@echo "Cognito redirect URLs and the parser's CORS read the site's origins from the frontend stack:"
	@echo "the next Terraform run picks them up (Actions -> Infra (Terraform) -> Run workflow, or any merge to main)."

.PHONY: aws-frontend-outputs
aws-frontend-outputs: ## Show frontend stack outputs (site URL, bucket, distribution)
	@aws cloudformation describe-stacks --stack-name $(FRONTEND_STACK) \
	  --query "Stacks[0].Outputs[].[OutputKey, OutputValue]" --output table

.PHONY: aws-frontend-destroy
aws-frontend-destroy: aws-check ## Empty the bucket and delete the frontend stack
	@read -p "Delete stack $(FRONTEND_STACK) in $(AWS_REGION)? [y/N] " ok && [ "$$ok" = y ]
	@bucket="$(call frontend_output,BucketName)"; [ -z "$$bucket" ] || aws s3 rm "s3://$$bucket" --recursive --quiet
	aws cloudformation delete-stack --stack-name $(FRONTEND_STACK)
	aws cloudformation wait stack-delete-complete --stack-name $(FRONTEND_STACK)

##@ AWS frontend custom domain (FRONTEND_DOMAIN, optional)

.PHONY: aws-frontend-cert
aws-frontend-cert: aws-check ## Request (or reuse) the ACM certificate for FRONTEND_DOMAIN (us-east-1) and set up DNS validation
	@$(CERT_SH) request $(FRONTEND_DOMAIN)

.PHONY: aws-frontend-cert-status
aws-frontend-cert-status: ## Show the certificate status and its DNS validation record
	@$(CERT_SH) status $(FRONTEND_DOMAIN)

.PHONY: aws-frontend-https
aws-frontend-https: aws-frontend-cert ## Attach FRONTEND_DOMAIN: wait for the certificate, add it to CloudFront, update CORS, set up DNS
	@$(CERT_SH) wait $(FRONTEND_DOMAIN)
	@$(MAKE) --no-print-directory aws-frontend-stack
	@$(MAKE) --no-print-directory aws-frontend-cors
	@$(MAKE) --no-print-directory aws-frontend-dns

.PHONY: aws-frontend-dns
aws-frontend-dns: ## Show the DNS record that points FRONTEND_DOMAIN at CloudFront
	@if [ -n "$(FRONTEND_ZONE_ID)" ]; then \
	  echo "Route 53 alias $(FRONTEND_DOMAIN) -> CloudFront is managed by stack $(FRONTEND_STACK) (zone $(FRONTEND_ZONE_ID))."; \
	else \
	  echo "Add this record at the DNS provider of $(FRONTEND_DOMAIN):"; echo; \
	  echo "  Type:  CNAME"; echo "  Name:  $(FRONTEND_DOMAIN)"; \
	  echo "  Value: $(call frontend_output,DistributionDomain)"; \
	fi
	@echo; echo "Site: $(call frontend_output,SiteUrl)   (check: make aws-frontend-https-check)"

.PHONY: aws-frontend-https-check
aws-frontend-https-check: ## Check that https://FRONTEND_DOMAIN answers
	@echo "DNS: $$(dig +short $(FRONTEND_DOMAIN) | tr '\n' ' ')"
	curl -fsS -o /dev/null -w "%{http_code} %{url_effective}\n" https://$(FRONTEND_DOMAIN)/

##@ Infrastructure as code (Terraform in infra/; state in S3; applied only by GitHub Actions)

TF := terraform -chdir=infra

.PHONY: infra-init
infra-init: ## terraform init (S3 backend, with the AWS credentials from .env)
	@$(LOAD_ENV) $(TF) init -input=false

.PHONY: infra-fmt
infra-fmt: ## terraform fmt
	$(TF) fmt -recursive

.PHONY: infra-validate
infra-validate: ## terraform fmt -check and validate (no AWS calls)
	$(TF) fmt -check -recursive
	@$(LOAD_ENV) $(TF) validate

.PHONY: infra-plan
infra-plan: ## Show what the pipeline would change (plan only: applies happen after a merge to main)
	@$(LOAD_ENV) $(TF) plan -input=false -lock-timeout=5m

.PHONY: infra-output
infra-output: ## Show the Terraform outputs (pool and client IDs, parser URL, queue URLs, ...)
	@$(LOAD_ENV) $(TF) output

.PHONY: infra-secrets
infra-secrets: aws-check ## Put the secrets from .env into SSM Parameter Store (SecureString) for Terraform; prints names only
	@test -n "$(GOOGLE_CLIENT_SECRET)" -a -n "$(REPORT_SENDER_EMAIL)" || { echo "Set GOOGLE_CLIENT_SECRET and REPORT_EMAIL in .env"; exit 1; }
	@put() { aws ssm put-parameter --name "/$(PROJECT)/terraform/$$1" --type SecureString --overwrite \
	    --value "$$2" --query Version --output text >/dev/null && \
	  aws ssm add-tags-to-resource --resource-type Parameter --resource-id "/$(PROJECT)/terraform/$$1" \
	    --tags Key=PROJECT_NAME,Value=$(PROJECT) && echo "/$(PROJECT)/terraform/$$1"; }; \
	put google_client_secret "$(GOOGLE_CLIENT_SECRET)" && \
	put openai_api_key "$(or $(OPENAI_API_KEY),none)" && \
	put report_sender_email "$(REPORT_SENDER_EMAIL)" && \
	put report_recipient_email "$(REPORT_RECIPIENT_EMAIL)" && \
	put budget_alert_email "$(BUDGET_EMAIL)"

##@ AWS auth (Cognito user pool with managed login: infra/auth.tf)

.PHONY: aws-cognito-env
aws-cognito-env: ## Print the .env lines for the deployed user pool (replace the empty COGNITO_* ones)
	@test -n "$(COGNITO_POOL_ID)" || { echo "No user pool in the Terraform outputs: run \`make infra-init\` (and see README)"; exit 1; }
	@echo
	@echo "Add to .env (replacing the empty COGNITO_* lines):"
	@echo
	@echo "COGNITO_REGION=$(AWS_REGION)"
	@echo "COGNITO_USER_POOL_ID=$(COGNITO_POOL_ID)"
	@echo "COGNITO_CLIENT_ID=$(COGNITO_CLIENT)"
	@echo "COGNITO_DOMAIN=$(COGNITO_DOMAIN)"
	@echo

##@ AWS reports (weekly CSV report: EventBridge Scheduler -> SQS -> Builder Lambda -> S3 -> Mailer Lambda -> SES; infra/reports.tf)

.PHONY: aws-reports-deploy
aws-reports-deploy: aws-check aws-backend-push ## Build/push the image and point the report builder at it
	@$(MAKE) --no-print-directory aws-lambda-image FUNCTION=$(REPORT_BUILDER_FUNCTION)
	@echo
	@echo "Reports bucket: $(call tf_output,reports_bucket_name)"
	@echo "Queue URL:      $(call tf_output,report_queue_url)"
	@echo "DLQ URL:        $(call tf_output,report_dlq_url)"

.PHONY: report-now
report-now: aws-check ## Send a report build request to SQS (e.g. `make report-now WEEK=2026-W40`)
	@queue="$(call tf_output,report_queue_url)"; \
	[ -n "$$queue" ] || { echo "No report queue in the Terraform outputs: run \`make infra-init\`"; exit 1; }; \
	week="$(WEEK)"; \
	if [ -z "$$week" ]; then \
	  week=$$(python3 -c 'import datetime; d = datetime.date.today() - datetime.timedelta(days=7); y, w, _ = d.isocalendar(); print(f"{y:04d}-W{w:02d}")'); \
	fi; \
	echo "Sending report request for $$week to $$queue"; \
	aws sqs send-message --queue-url "$$queue" --message-body "{\"week\": \"$$week\"}"

.PHONY: report-logs
report-logs: aws-check ## Show recent CloudWatch logs for both report-builder and report-mailer Lambdas
	@echo "=== /aws/lambda/$(REPORT_BUILDER_FUNCTION) ==="
	-aws logs tail /aws/lambda/$(REPORT_BUILDER_FUNCTION) --since 60m
	@echo
	@echo "=== /aws/lambda/$(REPORT_MAILER_FUNCTION) ==="
	-aws logs tail /aws/lambda/$(REPORT_MAILER_FUNCTION) --since 60m

##@ Lambda images (Terraform creates the functions; new image tags are deployed here)

.PHONY: aws-lambda-image
aws-lambda-image: ## Point FUNCTION at the image $(TAG) pushed by aws-backend-push
	@test -n "$(FUNCTION)" || { echo "Usage: make aws-lambda-image FUNCTION=<name>"; exit 1; }
	aws lambda update-function-code --function-name $(FUNCTION) --image-uri $(ECR_URI):$(TAG) \
	  --query "[FunctionName, LastUpdateStatus]" --output text
	aws lambda wait function-updated-v2 --function-name $(FUNCTION)

.PHONY: aws-lambda-images
aws-lambda-images: aws-check aws-backend-push ## Build/push the image, then deploy it to the report builder and the agenda parser
	@$(MAKE) --no-print-directory aws-lambda-image FUNCTION=$(REPORT_BUILDER_FUNCTION)
	@$(MAKE) --no-print-directory aws-lambda-image FUNCTION=$(PROJECT)-agenda-parser

##@ AWS (all parts)

.PHONY: aws-deploy
aws-deploy: aws-backend-deploy aws-lambda-images aws-frontend-deploy ## Deploy the application: backend stack, the Lambdas' image, then the frontend (infra/ itself is applied by the pipeline)

.PHONY: aws-destroy
aws-destroy: aws-frontend-destroy aws-backend-destroy ## Delete the CloudFormation stacks (each asks first); Terraform's resources: see README

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z_.-]+:.*?##/ { printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ AI agenda parser (Lab 6: Lambda + function URL; OpenAI API or Claude on Bedrock)

PARSER_PROVIDER ?= openai
PARSER_MODEL    ?= gpt-5.4-mini
BUDGET_EMAIL  = $(or $(BUDGET_ALERT_EMAIL),$(REPORT_EMAIL))
PARSER_URL    = $(call tf_output,parser_url)
# .env first, then the provider/model given to make (`make parse PARSER_PROVIDER=bedrock PARSER_MODEL=...`)
LLM_ENV       = set -a; [ -f .env ] && . ./.env; set +a; \
                export PARSER_PROVIDER=$(PARSER_PROVIDER) PARSER_MODEL=$(PARSER_MODEL);

.PHONY: aws-ai-deploy
aws-ai-deploy: aws-check aws-backend-push ## Build/push the image and point the parser at it (provider/model: infra/terraform.tfvars)
	@$(MAKE) --no-print-directory aws-lambda-image FUNCTION=$(PROJECT)-agenda-parser
	@echo "Parser URL: $(PARSER_URL)   (rebuild the frontend with: make aws-frontend-publish)"

.PHONY: aws-ai-logs
aws-ai-logs: ## Show parser logs (one JSON line per parse: model, tokens, latency, cost)
	aws logs tail /aws/lambda/$(PROJECT)-agenda-parser --since 60m

.PHONY: llm-hello
llm-hello: ## One call to the parser's LLM (PARSER_PROVIDER/PARSER_MODEL): answer, stop_reason, token usage
	@$(LLM_ENV) cd back && uv run python -m app.ai.cli hello

.PHONY: parse
parse: ## Parse pasted text: make parse TEXT="Mon 10:00 pricing sync 45m"
	@test -n "$(TEXT)" || { echo 'Usage: make parse TEXT="..."'; exit 1; }
	@$(LLM_ENV) cd back && uv run python -m app.ai.cli parse "$(TEXT)"

.PHONY: bedrock-check
bedrock-check: ## Is this AWS account ready for PARSER_PROVIDER=bedrock? Access, quotas, one call per Bedrock API
	@$(LLM_ENV) cd back && uv run python -m app.ai.bedrock_check

##@ Google Cloud (Lab 9: gcp/, see docs/lab9-report.md)

.PHONY: gcp-validate
gcp-validate: ## terraform init + fmt + validate in gcp/ (state key gcp/ in the S3 state bucket; no Google credentials needed)
	@$(LOAD_ENV) terraform -chdir=gcp init -input=false >/dev/null && terraform -chdir=gcp fmt -check -recursive && terraform -chdir=gcp validate

.PHONY: gcp-local
gcp-local: ## Run the backend image the way Cloud Run does (PORT=8080) next to PostgreSQL: http://localhost:8080/api/health
	docker build -q -t meetings-backend:cloudrun back
	-docker network create lab9 >/dev/null 2>&1
	-docker rm -f lab9-db lab9-api >/dev/null 2>&1
	docker run -d --name lab9-db --network lab9 -e POSTGRES_USER=meetings -e POSTGRES_PASSWORD=localpw -e POSTGRES_DB=meetings postgres:16-alpine
	sleep 5
	docker run -d --name lab9-api --network lab9 -e PORT=8080 -p 8080:8080 -e DB_HOST=lab9-db -e DB_USER=meetings \
	  -e DB_PASSWORD=localpw -e DB_NAME=meetings -e SEED=true meetings-backend:cloudrun
	@echo "API: http://localhost:8080/api/health   (stop: docker rm -f lab9-api lab9-db)"
