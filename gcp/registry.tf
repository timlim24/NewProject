# The counterpart of ECR. 0.5 GB is free, so only the newest images are kept.
resource "google_artifact_registry_repository" "backend" {
  repository_id = var.name
  location      = var.region
  format        = "DOCKER"
  description   = "Backend images for Cloud Run"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-latest-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      tag_state = "ANY"
    }
  }

  depends_on = [google_project_service.this]
}
