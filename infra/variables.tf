variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for resources"
}

variable "project_name" {
  type        = string
  default     = "new-project"
  description = "Prefix for resource names and tags"
}

variable "app_urls" {
  type        = list(string)
  default     = ["http://localhost:5173", "http://localhost:3000"]
  description = "Origins of the frontend (no trailing slash). OAuth redirects back to <origin>/login"
}

variable "google_client_id" {
  type        = string
  default     = ""
  description = "Google OAuth client id; leave empty to keep Google sign-in disabled"
}

variable "google_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth client secret"
}

variable "sender_email" {
  type        = string
  default     = ""
  description = "Verified SES sender email address for report mailer"
}

variable "recipient_email" {
  type        = string
  default     = ""
  description = "Verified SES recipient email address for report mailer"
}

variable "parser_model" {
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
  description = "Amazon Bedrock model ID for agenda parser"
}
