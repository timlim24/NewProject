# APIs are off in a new project. Enabling them here makes a fresh project reproducible.
# disable_on_destroy = false: `terraform destroy` removes the resources, not the API switches
# (turning an API off can fail while Google still cleans up behind it).
resource "google_project_service" "this" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}
