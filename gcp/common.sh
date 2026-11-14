# Shared setup for the gcp/ scripts. Google credentials come from the gcloud CLI
# (gcloud auth login + gcloud auth application-default login); there is no key file.
command -v gcloud >/dev/null || { echo "Install the gcloud CLI: https://cloud.google.com/sdk/docs/install" >&2; exit 1; }

GCP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$GCP_DIR/../infra"

# gcp_output KEY: one Terraform output of gcp/ (HCP Terraform workspace new-project-gcp).
gcp_output() {
  (cd "$GCP_DIR" && terraform output -raw "$1" 2>/dev/null || true)
}

# aws_output KEY: one Terraform output of infra/ (sign-in and the parser still run on AWS).
aws_output() {
  (cd "$INFRA_DIR" && terraform output -raw "$1" 2>/dev/null || true)
}

PROJECT_ID="${GCP_PROJECT_ID:-$(gcp_output project_id)}"
REGION="$(gcp_output region)"
[ -n "$PROJECT_ID" ] && [ -n "$REGION" ] || {
  echo "No outputs from gcp/: run 'terraform login' and 'cd gcp && terraform init', and apply gcp/ first." >&2
  exit 1
}
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
