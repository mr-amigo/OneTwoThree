variable "project_id" {
  type        = string
  description = "Google Cloud project ID (permanent, globally unique)."
}

variable "region" {
  type    = string
  default = "us-central1" # Cloud Run, Cloud SQL and the free tiers are all in us-central1
}

variable "name" {
  type        = string
  description = "Prefix of resource names and the project_name label."
  default     = "meetings"
}

variable "billing_account" {
  type        = string
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) for the budget alert; empty = no budget."
  default     = ""
}

variable "budget_amount" {
  type    = number
  default = 5
}

variable "image_tag" {
  type        = string
  description = "Tag of the backend image in Artifact Registry that Cloud Run starts with."
  default     = "latest"
}

variable "db_running" {
  type        = bool
  description = "false stops the Cloud SQL instance (storage is still billed, compute is not)."
  default     = true
}

variable "db_tier" {
  type    = string
  default = "db-f1-micro" # shared core, 0.6 GB: the smallest tier
}

# --- Sign-in stays on AWS: the API verifies Cognito ID tokens (infra/auth.tf) ---

variable "cognito_region" {
  type    = string
  default = "us-east-1"
}

variable "cognito_user_pool_id" {
  type        = string
  description = "Empty = auth off (every request is one local user): only for a private test."
}

variable "cognito_client_id" {
  type = string
}

variable "extra_cors_origins" {
  type        = list(string)
  description = "Browser origins allowed besides the Firebase Hosting site (local development)."
  default     = ["http://localhost:3000", "http://localhost:5173"]
}

# --- CI through Workload Identity Federation (GitHub Actions, no key) ---

variable "github_repository" {
  type    = string
  default = "mr-amigo/OneTwoThree"
}

variable "github_repository_id" {
  type        = number
  description = "Numeric IDs: a name can be re-registered by someone else, an ID cannot."
  default     = 1394976249
}

variable "github_owner_id" {
  type    = number
  default = 246989247
}
