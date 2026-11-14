variable "project_id" {
  type        = string
  description = "Google Cloud project ID (permanent, globally unique), e.g. spry-514721"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Default region"
}

variable "name" {
  type        = string
  default     = "new-project"
  description = "Prefix for resource names and the project_name label (same as PROJECT_NAME on AWS)"
}

variable "hcp_organization_id" {
  type        = string
  description = "HCP Terraform organization ID (org-...), from Organization settings. IDs, not names: a deleted name can be registered again by someone else"
}

variable "hcp_workspace_id" {
  type        = string
  description = "ID (ws-...) of the HCP Terraform workspace that applies gcp/, from its overview page"
}

variable "github_repository_id" {
  type        = string
  default     = ""
  description = "Numeric GitHub repository ID (gh api repos/OWNER/REPO --jq .id). Empty: no GitHub Actions access"
}

variable "github_repository_owner_id" {
  type        = string
  default     = ""
  description = "Numeric ID of the repository owner (gh api repos/OWNER/REPO --jq .owner.id)"
}
