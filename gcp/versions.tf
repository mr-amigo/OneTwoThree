# Lab 9: the core of the app (frontend, API, database) on Google Cloud.
#
#   Firebase Hosting (SPA, /api/** rewritten to Cloud Run) -> Cloud Run (the same FastAPI image, no
#   Lambda adapter) -> Cloud SQL for PostgreSQL (db-f1-micro) over the Cloud SQL connector.
#   Sign-in (Cognito), the weekly report and the agenda parser stay on AWS (infra/).
#
# Separate from infra/: its own state (key gcp/ in the project's state bucket), its own provider,
# so one plan cannot break both clouds. Credentials: application default credentials on a laptop
# (gcloud auth application-default login), Workload Identity Federation in CI (wif.tf). No key files.

terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "meetings-tfstate-027824090051"
    key          = "gcp/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project_name = var.name
    managed_by   = "terraform"
  }
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project_name = var.name
    managed_by   = "terraform"
  }
}

data "google_project" "this" {}
