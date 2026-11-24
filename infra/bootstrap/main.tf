# Bootstrap: the pieces that must exist before the pipeline can run Terraform.
#
#   - an S3 bucket for the state of infra/ (versioned, encrypted, private; S3 lock files, no DynamoDB);
#   - an IAM OIDC provider for GitHub Actions;
#   - two roles that only workflows of this repository may assume:
#       github-terraform-<project>-plan   read-only; pull requests and manual plans (drift checks);
#       github-terraform-<project>-apply  changes the infrastructure; only runs on the main branch.
#
# Why GitHub Actions and not HCP Terraform: in November 2026 HCP Terraform refused to create a free
# organization for this account ("Free tier organizations created by user limit reached", for a
# personal and a business organization, with and without an HCP account). See docs/adr/0007-terraform.md.
#
# Applied once from a laptop with an administrator's credentials. The state of this folder stays local
# (infra/bootstrap/terraform.tfstate, not in Git); if it is lost, re-adopt the resources with import blocks.
#
#   cd infra/bootstrap && terraform init && terraform apply

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform-bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "meetings"
}

variable "github_repository" {
  type        = string
  description = "owner/name of the repository whose workflows may assume the roles."
  default     = "mr-amigo/OneTwoThree"
}

# GitHub's OIDC subject names the owner and the repository with their immutable IDs as well
# (repo:<owner>@<owner id>/<repo>@<repo id>:...), so a repository deleted and re-created under the same
# name by someone else does not get these roles. IDs: https://api.github.com/repos/<owner>/<repo>
variable "github_owner_id" {
  type    = number
  default = 246989247
}

variable "github_repository_id" {
  type    = number
  default = 1394976249
}

data "aws_caller_identity" "current" {}

data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = var.region
  p       = var.project_name
  repo = format("%s@%d/%s@%d",
    split("/", var.github_repository)[0], var.github_owner_id,
    split("/", var.github_repository)[1], var.github_repository_id,
  )
}

# --- Remote state ---

resource "aws_s3_bucket" "state" {
  bucket = "${local.p}-tfstate-${local.account}"

  # The only record of what Terraform owns. Losing it means re-importing every resource.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  # Every state version is kept, so a bad apply can be rolled back to the previous state file.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }
  }
}

# --- GitHub Actions OIDC ---

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # Who may assume which role. The sub claim names the repository (with IDs) and the event or branch.
  plan_subjects = [
    "repo:${local.repo}:pull_request",
    "repo:${local.repo}:ref:refs/heads/main",
  ]
  apply_subjects = ["repo:${local.repo}:ref:refs/heads/main"]

  state_access = [
    {
      Sid      = "StateBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
      Resource = aws_s3_bucket.state.arn
    },
    {
      # The state file and its .tflock lock file.
      Sid      = "StateObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.state.arn}/${local.p}/*"
    },
    {
      Sid      = "TerraformSecrets"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${local.region}:${local.account}:parameter/${local.p}/terraform/*"
    },
    {
      Sid      = "DatabasePassword"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = data.aws_cloudformation_stack.backend.outputs["DbSecretArn"]
    },
  ]
}

data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.apply_subjects
    }
  }
}

# --- Plan role: read-only. A pull request can change the workflow file, so whatever runs on a pull
# --- request must not be able to change anything.

resource "aws_iam_role" "plan" {
  name                 = "github-terraform-${local.p}-plan"
  description          = "terraform plan from GitHub Actions (${var.github_repository}): pull requests and manual plans"
  assume_role_policy   = data.aws_iam_policy_document.trust_plan.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan" {
  name = "state-and-secrets"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.state_access
  })
}

# --- Apply role: only the main branch. Instead of AdministratorAccess, the services this
# --- configuration manages, and where the ARN carries the name, only resources named <project>-*.
# --- The two GitHub roles are named github-terraform-*, so the apply role cannot edit them.

resource "aws_iam_role" "apply" {
  name                 = "github-terraform-${local.p}-apply"
  description          = "terraform apply from GitHub Actions (${var.github_repository}), main branch only"
  assume_role_policy   = data.aws_iam_policy_document.trust_apply.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "apply" {
  name = "manage-${local.p}-infrastructure"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.state_access, [
      {
        Sid      = "ReadOtherStacksOutputs"
        Effect   = "Allow"
        Action   = ["cloudformation:DescribeStacks", "cloudformation:GetTemplate"] # the data source reads both
        Resource = "arn:aws:cloudformation:${local.region}:${local.account}:stack/${local.p}-*/*"
      },
      {
        Sid    = "LambdaFunctions"
        Effect = "Allow"
        Action = "lambda:*"
        Resource = [
          "arn:aws:lambda:${local.region}:${local.account}:function:${local.p}-*",
          "arn:aws:lambda:${local.region}:${local.account}:event-source-mapping:*",
        ]
      },
      {
        Sid      = "LambdaEventSourceMappings"
        Effect   = "Allow"
        Action   = ["lambda:CreateEventSourceMapping", "lambda:ListEventSourceMappings", "lambda:GetEventSourceMapping"]
        Resource = "*"
      },
      {
        # Lambda pulls the image with the caller's rights when it creates an image function.
        Sid      = "PullBackendImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:GetRepositoryPolicy", "ecr:SetRepositoryPolicy"]
        Resource = "arn:aws:ecr:${local.region}:${local.account}:repository/${local.p}-*"
      },
      {
        Sid    = "ProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags", "iam:PassRole",
          "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = "arn:aws:iam::${local.account}:role/${local.p}-*"
      },
      {
        Sid      = "ReportsBucket"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:aws:s3:::${local.p}-reports-*"
      },
      {
        Sid      = "ProjectQueues"
        Effect   = "Allow"
        Action   = "sqs:*"
        Resource = "arn:aws:sqs:${local.region}:${local.account}:${local.p}-*"
      },
      {
        Sid    = "ProjectLogGroups"
        Effect = "Allow"
        Action = "logs:*"
        Resource = [
          "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/lambda/${local.p}-*",
          "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/lambda/${local.p}-*:*",
        ]
      },
      {
        Sid      = "ListLogGroups"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
      {
        Sid      = "ProjectSchedules"
        Effect   = "Allow"
        Action   = "scheduler:*"
        Resource = "arn:aws:scheduler:${local.region}:${local.account}:schedule/default/${local.p}-*"
      },
      {
        Sid      = "ProjectBudgets"
        Effect   = "Allow"
        Action   = "budgets:*"
        Resource = "arn:aws:budgets::${local.account}:budget/${local.p}-*"
      },
      {
        # User pools and SES identities carry no project name in their ARNs, so these two services
        # are allowed account-wide in this region. A team would scope them by tag.
        Sid       = "CognitoAndSes"
        Effect    = "Allow"
        Action    = ["cognito-idp:*", "ses:*"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
      {
        # The S3 gateway endpoint, and the network lookups Lambda makes for a function in the VPC.
        Sid    = "VpcEndpointAndNetworkReads"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:CreateVpcEndpoint", "ec2:ModifyVpcEndpoint", "ec2:DeleteVpcEndpoints",
          "ec2:CreateTags", "ec2:DeleteTags",
        ]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
      },
    ])
  })
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
