# APIs that identities and federation need. gcp/ enables the APIs of the app itself.
resource "google_project_service" "bootstrap" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# --- Service accounts: one per program ------------------------------------------------------

# Terraform for gcp/, run by HCP Terraform. Only the predefined roles it needs, no Owner/Editor.
resource "google_service_account" "terraform" {
  account_id   = "terraform"
  display_name = "Terraform (HCP Terraform workspace for gcp/)"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_project_iam_member" "terraform" {
  for_each = toset([
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

# The identity the API runs as on Cloud Run (not the default compute account, which has Editor).
resource "google_service_account" "api" {
  account_id   = "${var.name}-api"
  display_name = "Spry API on Cloud Run"
  depends_on   = [google_project_service.bootstrap]
}

# Connect to Cloud SQL through the Cloud Run connection. Granted here rather than in gcp/,
# so the Terraform account does not need to change project IAM.
resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

# Service Account User only on the API's account, not on the project: Terraform may deploy
# Cloud Run as this one identity and no other.
resource "google_service_account_iam_member" "terraform_acts_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.terraform.member
}

# --- Workload Identity Federation: short-lived tokens instead of keys ------------------------

resource "google_iam_workload_identity_pool" "ci" {
  workload_identity_pool_id = "external-ci"
  display_name              = "CI and HCP Terraform"
  depends_on                = [google_project_service.bootstrap]
}

# HCP Terraform presents an OIDC token per run; only runs of our workspace are admitted.
resource "google_iam_workload_identity_pool_provider" "hcp_terraform" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.ci.workload_identity_pool_id
  workload_identity_pool_provider_id = "hcp-terraform"
  display_name                       = "HCP Terraform"

  attribute_mapping = {
    "google.subject"                      = "assertion.sub"
    "attribute.terraform_organization_id" = "assertion.terraform_organization_id"
    "attribute.terraform_workspace_id"    = "assertion.terraform_workspace_id"
    "attribute.terraform_full_workspace"  = "assertion.terraform_full_workspace"
    "attribute.terraform_run_phase"       = "assertion.terraform_run_phase"
  }
  attribute_condition = "assertion.terraform_organization_id == '${var.hcp_organization_id}' && assertion.terraform_workspace_id == '${var.hcp_workspace_id}'"

  oidc {
    issuer_uri = "https://app.terraform.io"
  }
}

resource "google_service_account_iam_member" "terraform_wif" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.ci.name}/attribute.terraform_workspace_id/${var.hcp_workspace_id}"
}

# GitHub Actions (stretch: deploy the app from CI). Only this repository, by numeric IDs.
locals {
  github_enabled = var.github_repository_id != "" && var.github_repository_owner_id != ""
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = local.github_enabled ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.ci.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
  }
  attribute_condition = "assertion.repository_id == '${var.github_repository_id}' && assertion.repository_owner_id == '${var.github_repository_owner_id}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# The application road from CI: push images, roll out a new Cloud Run revision, publish
# the frontend to Firebase Hosting.
resource "google_service_account" "deployer" {
  count = local.github_enabled ? 1 : 0

  account_id   = "deployer"
  display_name = "App deploys from GitHub Actions"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_project_iam_member" "deployer" {
  for_each = local.github_enabled ? toset([
    "roles/artifactregistry.writer",
    "roles/run.developer",
    "roles/firebasehosting.admin",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = google_service_account.deployer[0].member
}

resource "google_service_account_iam_member" "deployer_acts_as_api" {
  count = local.github_enabled ? 1 : 0

  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer[0].member
}

resource "google_service_account_iam_member" "deployer_wif" {
  count = local.github_enabled ? 1 : 0

  service_account_id = google_service_account.deployer[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.ci.name}/attribute.repository_id/${var.github_repository_id}"
}
