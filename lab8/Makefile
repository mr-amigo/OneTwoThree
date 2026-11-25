# Lab 8: Big Data on AWS. Run from the repository root: `make -C lab8 <target>`, or from lab8/.
# AWS credentials come from ../.env (as for the rest of the project). LAB8_ALERT_EMAIL in .env is the
# address of the SNS alert. This is a lab sandbox applied from a laptop; see infra/versions.tf.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENV      := set -a; [ -f ../.env ] && . ../.env; set +a; export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 TF_VAR_alert_email="$${LAB8_ALERT_EMAIL:-}";
TF       := terraform -chdir=infra
SOURCE   := s3://ucu-ooad-lab8-payments/payments/
BUCKET    = $(shell $(ENV) $(TF) output -raw bucket 2>/dev/null)
PY       := uv run --quiet

.PHONY: help
help: ## List the targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_.-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: init
init: ## terraform init (state in the project's S3 state bucket, key lab8/)
	@$(ENV) $(TF) init -input=false

.PHONY: plan
plan: ## terraform plan
	@$(ENV) $(TF) plan -input=false

.PHONY: up
up: ## Part 2 resources: bucket, Athena workgroup, Glue database and crawler, SNS topic (no streaming)
	@$(ENV) $(TF) apply -input=false -var streaming_enabled=false

.PHONY: copy
copy: ## Copy the dataset into our bucket (S3 -> S3 inside us-east-1: no transfer cost)
	@$(ENV) aws s3 sync $(SOURCE) s3://$(BUCKET)/payments/ --only-show-errors --copy-props none # the public bucket does not allow reading object tags
	@$(ENV) aws s3 ls s3://$(BUCKET)/payments/ --recursive --summarize | tail -2

.PHONY: crawl
crawl: ## Way B: run the Glue crawler and print the schema it inferred
	@$(ENV) $(PY) scripts/crawl.py

.PHONY: part2
part2: ## Way A: run sql/*.sql in Athena; results and stats into ../docs/lab8-runs/part2/
	@$(ENV) $(PY) scripts/athena.py sql/part2 ../docs/lab8-runs/part2

.PHONY: stream-on
stream-on: ## Part 3: create the Kinesis stream, Firehose and the alert consumer (billed per hour)
	@$(ENV) $(TF) apply -input=false -var streaming_enabled=true

.PHONY: produce
produce: ## Part 3: replay one day of events into the stream (DAY=2026-10-01 RATE=800 DRILL=1)
	@$(ENV) $(PY) producer/producer.py --stream ooad-lab8-payments --day $(or $(DAY),2026-10-01) \
	  --rate $(or $(RATE),800) $(if $(DRILL),--drill) $(if $(LIMIT),--limit $(LIMIT))

.PHONY: part3
part3: ## Part 3: query the data that came through the stream; results into ../docs/lab8-runs/part3/
	@$(ENV) $(PY) scripts/athena.py sql/part3 ../docs/lab8-runs/part3

.PHONY: stream-off
stream-off: ## Delete the Kinesis stream, Firehose and the consumer (the data in S3 stays)
	@$(ENV) $(TF) apply -input=false -var streaming_enabled=false

.PHONY: destroy
destroy: ## Delete everything of Lab 8, the bucket and its data included
	@$(ENV) $(TF) destroy -input=false
