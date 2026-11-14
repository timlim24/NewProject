# Spry's core on Google Cloud: Cloud SQL, Artifact Registry, Secret Manager and the API on
# Cloud Run. Separate from infra/ (AWS) with its own HCP Terraform workspace and state, so one
# plan can never break both clouds.
#
# HCP Terraform authenticates to Google with Workload Identity Federation (gcp/bootstrap/):
# workspace env vars TFC_GCP_PROVIDER_AUTH, TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL and
# TFC_GCP_WORKLOAD_PROVIDER_NAME. No service account key exists anywhere.
terraform {
  required_version = ">= 1.10"

  cloud {
    organization = "ooad-timlim"

    workspaces {
      name = "new-project-gcp"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # The GCP counterpart of the PROJECT_NAME tag on AWS: filter Billing reports by this label.
  default_labels = {
    project_name = var.name
    managed_by   = "terraform"
  }
}

locals {
  # Firebase Hosting serves the frontend on both of these.
  frontend_origins = [
    "https://${var.project_id}.web.app",
    "https://${var.project_id}.firebaseapp.com",
  ]
  # Created by gcp/bootstrap/, together with its Cloud SQL Client role.
  api_service_account = "${var.name}-api@${var.project_id}.iam.gserviceaccount.com"
}
