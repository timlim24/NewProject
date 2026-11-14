# The FastAPI backend on Cloud Run: the same container as locally, no Lambda adapter.
# Terraform owns the service's configuration; the image is the application road
# (make gcp-deploy-backend), so a new image never needs a Terraform run.
resource "google_cloud_run_v2_service" "api" {
  name                = "${var.name}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  # Public without an allUsers binding: Cloud Run skips the invoker IAM check. Organizations
  # created after May 2024 enforce "Restrict identities by domain"
  # (iam.allowedPolicyMemberDomains), which rejects allUsers in any IAM policy. Every route except
  # /api/health checks a Cognito ID token itself, and Firebase Hosting's /api rewrite needs the
  # service to be callable without Google credentials.
  invoker_iam_disabled = true

  template {
    service_account = local.api_service_account

    scaling {
      # Scales to zero: an idle month costs nothing.
      min_instance_count = 0
      max_instance_count = var.api_max_instances
    }

    max_instance_request_concurrency = 40

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      # Placeholder until the first `make gcp-deploy-backend`; ignored afterwards.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Request-based billing: CPU only while a request is in flight.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      # 2 instances x (2 + 2) connections stays well under db-f1-micro's 25.
      env {
        name  = "DB_POOL_SIZE"
        value = "2"
      }
      env {
        name  = "DB_MAX_OVERFLOW"
        value = "2"
      }
      # Same-origin through the Firebase /api rewrite; CORS only matters for direct calls.
      env {
        name  = "CORS_ORIGINS"
        value = join(",", concat(local.frontend_origins, ["http://localhost:5173"]))
      }
      # Cloud Run has internet access, so the API downloads Cognito's signing keys itself.
      env {
        name  = "COGNITO_USER_POOL_ID"
        value = var.cognito_user_pool_id
      }
      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  # A revision only starts once it can read its secret.
  depends_on = [
    google_project_service.this,
    google_secret_manager_secret_version.database_url,
    google_secret_manager_secret_iam_member.api_reads_database_url,
  ]
}
