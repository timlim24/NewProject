# Cloud SQL for PostgreSQL, the smallest shared-core tier. Unlike Aurora it does not pause:
# it bills $0.0105/h until stopped (make gcp-db-stop). Storage bills while stopped too.

# Instance names stay reserved for about a week after deletion; the suffix lets
# destroy-then-apply work straight away.
resource "random_id" "db" {
  byte_length = 2
}

resource "google_sql_database_instance" "main" {
  name             = "${var.name}-db-${random_id.db.hex}"
  database_version = "POSTGRES_17"
  region           = var.region

  # Lab project: `terraform destroy` must be able to delete it. Turn both on for real data.
  deletion_protection = false

  settings {
    # Shared-core tiers exist only in Enterprise edition (PostgreSQL 16+ defaults to Plus).
    edition           = "ENTERPRISE"
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = false

    deletion_protection_enabled = false

    # Backups bill storage; the data is reproducible from migrations + seed.
    backup_configuration {
      enabled = false
    }

    # Public IP with no authorized networks: nothing can connect directly. Cloud Run reaches it
    # through the Cloud SQL connection (IAM-authorised, encrypted), with no VPC to pay for.
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }
  }

  lifecycle {
    # Starting and stopping is an operation, not configuration (make gcp-db-stop / -start),
    # the way Aurora pausing is. Terraform creates it running and leaves the switch alone.
    ignore_changes = [settings[0].activation_policy]
  }

  depends_on = [google_project_service.this]
}

resource "google_sql_database" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
  # Dropping a database with open connections fails; destroying the instance removes it anyway.
  deletion_policy = "ABANDON"
}

# Generated here, never in the repository. Alphanumeric so it fits in a URL unescaped.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
  # PostgreSQL refuses to drop a role that owns tables; the instance takes it with it.
  deletion_policy = "ABANDON"
}

# The API reads its connection string (password included) from Secret Manager at startup.
# Cloud Run mounts the instance's Unix socket at /cloudsql/<connection name>.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "${var.name}-database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url.id
  secret_data = "postgresql+asyncpg://${google_sql_user.app.name}:${random_password.db.result}@/${google_sql_database.app.name}?host=/cloudsql/${google_sql_database_instance.main.connection_name}"
}

# Only the API's identity may read it, and only this secret.
resource "google_secret_manager_secret_iam_member" "api_reads_database_url" {
  secret_id = google_secret_manager_secret.database_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.api_service_account}"
}
