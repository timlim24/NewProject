# Set these three as Environment Variables of the gcp/ workspace in HCP Terraform.
output "TFC_GCP_PROVIDER_AUTH" {
  value = "true"
}

output "TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL" {
  value = google_service_account.terraform.email
}

output "TFC_GCP_WORKLOAD_PROVIDER_NAME" {
  value       = google_iam_workload_identity_pool_provider.hcp_terraform.name
  description = "projects/<number>/locations/global/workloadIdentityPools/external-ci/providers/hcp-terraform"
}

output "api_service_account" {
  value = google_service_account.api.email
}

# For google-github-actions/auth in a workflow (stretch).
output "github_workload_identity_provider" {
  value = local.github_enabled ? google_iam_workload_identity_pool_provider.github[0].name : null
}

output "github_service_account" {
  value = local.github_enabled ? google_service_account.deployer[0].email : null
}
