# Non-secret values are in terraform.tfvars (in Git). Secrets and personal email addresses are not
# variables: they are SecureString parameters in SSM Parameter Store under /<project_name>/terraform/
# (see data.tf and `make infra-secrets`), so neither the repository nor the CI logs ever hold them.

variable "project_name" {
  type        = string
  description = "Name prefix of every resource; also the PROJECT_NAME tag."
  default     = "meetings"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "architecture" {
  type        = string
  description = "Lambda CPU architecture; must match the backend container image."
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "local_origins" {
  type        = list(string)
  description = "Browser origins allowed besides the site's (local development)."
  default     = ["http://localhost:3000", "http://localhost:5173"]
}

# --- Auth (Lab 4) ---

variable "google_client_id" {
  type        = string
  description = "OAuth client ID (Web application) from Google Cloud. Public: it appears in every sign-in URL."
}

# --- Weekly report (Lab 5) ---

variable "report_schedule_expression" {
  type    = string
  default = "cron(0 7 ? * MON *)"
}

variable "report_schedule_timezone" {
  type    = string
  default = "Europe/Kyiv"
}

variable "report_schedule_target" {
  type        = string
  description = "SQS sends the scheduled event through the queue; LAMBDA invokes the builder directly."
  default     = "SQS"

  validation {
    condition     = contains(["SQS", "LAMBDA"], var.report_schedule_target)
    error_message = "report_schedule_target must be SQS or LAMBDA."
  }
}

variable "report_fail_on_week" {
  type        = string
  description = "ISO week (e.g. 2026-W99) on which the builder fails on purpose, to test the DLQ."
  default     = ""
}

variable "report_log_retention_days" {
  type    = number
  default = 7
}

# --- Agenda parser (Lab 6) ---

variable "parser_provider" {
  type    = string
  default = "openai"

  validation {
    condition     = contains(["openai", "bedrock", "bedrock-converse"], var.parser_provider)
    error_message = "parser_provider must be openai, bedrock or bedrock-converse."
  }
}

variable "parser_model" {
  type    = string
  default = "gpt-5.4-mini"
}

variable "budget_enabled" {
  type        = bool
  description = "Create the $5 monthly budget alarm (sent to /<project_name>/terraform/budget_alert_email)."
  default     = true
}

