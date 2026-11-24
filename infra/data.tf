# Values that come from the stacks still in CloudFormation (Labs 2-4): network, database, image
# repository and site. Terraform reads their outputs; it does not manage them.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

data "aws_cloudformation_stack" "backend_ecr" {
  name = "${var.project_name}-backend-ecr"
}

data "aws_cloudformation_stack" "frontend" {
  name = "${var.project_name}-frontend"
}

# The database password, for the report builder's environment. It ends up in the state (encrypted
# at rest in the S3 state bucket) and is shown as (sensitive value) in plans.
data "aws_secretsmanager_secret_version" "db" {
  secret_id = local.backend["DbSecretArn"]
}

# Secrets and personal addresses, put there once by `make infra-secrets` (from .env). Their values end
# up in the state, which is why the state bucket is private and encrypted; plans show (sensitive value).
data "aws_ssm_parameter" "secret" {
  for_each = toset([
    "google_client_secret",
    "openai_api_key",
    "report_sender_email",
    "report_recipient_email",
    "budget_alert_email",
  ])

  name            = "/${var.project_name}/terraform/${each.key}"
  with_decryption = true
}

locals {
  secret = { for name, p in data.aws_ssm_parameter.secret : name => p.value }

  account_id = data.aws_caller_identity.current.account_id
  backend    = data.aws_cloudformation_stack.backend.outputs

  # The Lambdas share the backend image. Terraform creates a function with :latest; after that,
  # `make aws-lambda-images` deploys new tags, so image_uri is ignored in the functions' lifecycle.
  image_uri = "${data.aws_cloudformation_stack.backend_ecr.outputs["RepositoryUri"]}:latest"

  # Browser origins: local development plus the site (and its custom domain once attached).
  cors_origins = concat(var.local_origins, split(",", data.aws_cloudformation_stack.frontend.outputs["SiteOrigins"]))
}
