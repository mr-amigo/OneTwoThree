# Lab 8 sandbox: the payments lake (S3 + Glue + Athena) and the streaming pipeline
# (Kinesis -> Firehose -> S3 Parquet -> Athena, Lambda window alert -> SNS).
#
# This is a lab experiment, not part of the product, so it is applied from a laptop (lab8/Makefile)
# with its own state, and the paid streaming part is switched off again with streaming_enabled = false.
# The product's infrastructure (infra/) still changes only through the pipeline (ADR 0007).

terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "meetings-tfstate-027824090051"
    key          = "lab8/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
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

  default_tags {
    tags = {
      PROJECT_NAME = var.name
      ManagedBy    = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  bucket  = "${var.name}-${local.account}"
}
