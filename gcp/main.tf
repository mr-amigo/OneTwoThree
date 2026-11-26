# --- APIs: off by default in a new project; enabled here so a fresh project is reproducible ---

locals {
  services = [
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "sts.googleapis.com",
  ]
  site_origin  = "https://${var.project_id}.web.app"
  cors_origins = concat([local.site_origin, "https://${var.project_id}.firebaseapp.com"], var.extra_cors_origins)
  image        = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/backend:${var.image_tag}"
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
}

# --- Budget alert: e-mails at 50%, 90% and 100% of $5 (it alerts, it does not stop spending) ---

resource "google_billing_budget" "monthly" {
  count           = var.billing_account == "" ? 0 : 1
  billing_account = var.billing_account
  display_name    = "${var.name} ${var.project_id} $${var.budget_amount}/month"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }

  depends_on = [google_project_service.enabled]
}

# --- Artifact Registry: the backend image (0.5 GB free) ---

resource "google_artifact_registry_repository" "images" {
  repository_id = var.name
  format        = "DOCKER"
  description   = "Backend images for Cloud Run"

  cleanup_policies {
    id     = "keep-last-5"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "604800s" # 7 days; the KEEP rule above wins for the newest 5
    }
  }

  depends_on = [google_project_service.enabled]
}

# --- The API's own identity (not the default compute account, which starts with Editor) ---

resource "google_service_account" "api" {
  account_id   = "${var.name}-api"
  display_name = "Cloud Run API (${var.name})"
}

resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# --- Cloud SQL for PostgreSQL ---

resource "random_password" "db" {
  length  = 32
  special = false # the password also travels in env vars and URLs; letters and digits are enough at this length
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.name}-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_secret_manager_secret_iam_member" "api_reads_db_password" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_sql_database_instance" "db" {
  name                = "${var.name}-db"
  database_version    = "POSTGRES_16"
  deletion_protection = false # a lab: terraform destroy must be able to remove it

  settings {
    tier              = var.db_tier
    edition           = "ENTERPRISE"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = false
    availability_type = "ZONAL"
    activation_policy = var.db_running ? "ALWAYS" : "NEVER"

    ip_configuration {
      # A public IP with no authorized networks: only the Cloud SQL connector (IAM-authorized, TLS)
      # can reach it, the way Cloud Run connects. No VPC connector, which would bill by the hour.
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = false # demo data; a real deployment turns on backups and point-in-time recovery
    }

    user_labels = {
      project_name = var.name
    }
  }

  depends_on = [google_project_service.enabled]
}

resource "google_sql_database" "app" {
  name     = var.name
  instance = google_sql_database_instance.db.name
}

resource "google_sql_user" "app" {
  name     = var.name
  instance = google_sql_database_instance.db.name
  password = random_password.db.result
}

# --- Cloud Run: the same FastAPI image that runs in Docker Compose ---

resource "google_cloud_run_v2_service" "api" {
  name                = "${var.name}-api"
  location            = var.region
  deletion_protection = false
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 0 # scales to zero: an idle API costs nothing
      max_instance_count = 2
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.db.connection_name]
      }
    }

    containers {
      image = local.image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true # request-based billing: CPU only while a request is served
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "DB_HOST"
        value = "/cloudsql/${google_sql_database_instance.db.connection_name}" # Unix socket of the connector
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.app.name
      }
      env {
        name  = "DB_USER"
        value = google_sql_user.app.name
      }
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DB_NULL_POOL"
        value = "false" # a long-lived container keeps a small pool, unlike Lambda
      }
      env {
        name  = "SEED"
        value = "true" # sample participants on an empty database
      }
      env {
        name  = "CORS_ORIGINS"
        value = join(",", local.cors_origins)
      }
      env {
        name  = "COGNITO_REGION"
        value = var.cognito_region
      }
      env {
        name  = "COGNITO_USER_POOL_ID"
        value = var.cognito_user_pool_id
      }
      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }

      startup_probe {
        initial_delay_seconds = 0
        period_seconds        = 5
        failure_threshold     = 24 # migrations run on start; the first start also waits for Cloud SQL
        tcp_socket {
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_secret_manager_secret_iam_member.api_reads_db_password,
    google_project_iam_member.api_sql_client,
  ]

  lifecycle {
    # CI deploys new images (gcloud run deploy --image); Terraform owns everything else.
    ignore_changes = [template[0].containers[0].image, client, client_version]
  }
}

# Public: the API checks Cognito ID tokens itself (401 without one); /api/health is the only open read.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Firebase Hosting: the SPA, with /api/** rewritten to Cloud Run (one origin, no CORS) ---

resource "google_firebase_project" "this" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [google_project_service.enabled]
}

resource "google_firebase_hosting_site" "default" {
  provider = google-beta
  project  = var.project_id
  site_id  = var.project_id

  depends_on = [google_firebase_project.this]
}
