variable "project_id" {
  type        = string
  description = "Google Cloud project ID"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Region for Cloud Run, Cloud SQL and Artifact Registry"
}

variable "name" {
  type        = string
  default     = "new-project"
  description = "Prefix for resource names (same as PROJECT_NAME on AWS)"
}

variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Cloud SQL machine type; db-f1-micro is the smallest shared-core tier ($0.0105/h)"
}

variable "api_max_instances" {
  type        = number
  default     = 2
  description = "Upper bound on Cloud Run instances: caps the bill and the connections to db-f1-micro (max 25)"
}

# Sign-in stays on AWS for now: the API accepts ID tokens from the existing Cognito pool.
# Public identifiers (they are in the frontend bundle), from `terraform output` in infra/.
variable "cognito_user_pool_id" {
  type        = string
  description = "Cognito user pool ID whose ID tokens the API accepts"
}

variable "cognito_client_id" {
  type        = string
  description = "Cognito app client ID (the token audience)"
}
