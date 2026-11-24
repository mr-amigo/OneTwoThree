# Terraform for the parts of the project added in Labs 4-6: Cognito (auth.tf), the weekly report
# (reports.tf) and the agenda parser (ai.tf). The older stacks (network + API + database, ECR, site)
# stay in CloudFormation; this configuration reads their outputs (data.tf).
#
# The state is in S3 (versioned, encrypted, with an S3 lock file). GitHub Actions runs Terraform:
# plan on every pull request with a read-only role, apply after a merge to main with the apply role,
# both through OIDC, no AWS keys anywhere (.github/workflows/infra.yml). The bucket and the roles come
# from infra/bootstrap. HCP Terraform was the first choice; why it is not used: docs/adr/0007-terraform.md.

terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "meetings-tfstate-027824090051"
    key          = "meetings/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # a .tflock object next to the state; no DynamoDB table
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource that takes tags gets them without repeating them (the Lab 4 tagging rule).
  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}
