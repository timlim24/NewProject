# Read by gcp/deploy-*.sh.
output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "api_service" {
  value = google_cloud_run_v2_service.api.name
}

output "api_url" {
  value       = google_cloud_run_v2_service.api.uri
  description = "Cloud Run URL of the API (the frontend reaches it through Firebase at /api)"
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.backend.repository_id}/backend"
}

output "db_instance" {
  value = google_sql_database_instance.main.name
}

output "db_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "app_urls" {
  value = local.frontend_origins
}
