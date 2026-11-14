# One-time bootstrap of the Google Cloud project: the identities and the trust that let HCP
# Terraform (and GitHub Actions) act on the project without a service account key.
#
# It cannot configure itself (HCP Terraform has no access before this exists), so a project
# owner applies it once from a laptop, signed in with `gcloud auth application-default login`.
# The state lives in HCP Terraform; set this workspace's Execution Mode to "Local" so the run
# uses the laptop's credentials.
terraform {
  required_version = ">= 1.10"

  cloud {
    organization = "ooad-timlim"

    workspaces {
      name = "new-project-gcp-bootstrap"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project_name = var.name
    managed_by   = "terraform"
  }
}
