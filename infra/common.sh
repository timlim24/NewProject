# Shared setup for the infra scripts: credentials and settings come from .env via make.
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID in .env}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY in .env}"
: "${AWS_REGION:?Set AWS_REGION in .env}"
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
[ -n "${AWS_SESSION_TOKEN:-}" ] || unset AWS_SESSION_TOKEN

# APP_NAME is the old name of the setting and still works.
PROJECT_NAME="${PROJECT_NAME:-${APP_NAME:-meetings}}"
ECR_STACK="$PROJECT_NAME-ecr"
BACKEND_STACK="$PROJECT_NAME-backend"
FRONTEND_STACK="$PROJECT_NAME-frontend"
AUTH_STACK="$PROJECT_NAME-auth"
# CloudFront only accepts certificates from us-east-1.
CERT_STACK="$PROJECT_NAME-certificate"
CERT_REGION="us-east-1"

# Every resource is tagged PROJECT_NAME=<PROJECT_NAME>: explicitly in the templates, via the
# stack tags (which also cover resources CloudFormation creates implicitly), and by the
# scripts for resources created outside CloudFormation.
TAG_KEY="PROJECT_NAME"
STACK_TAGS=("$TAG_KEY=$PROJECT_NAME")

# output STACK KEY [REGION]: prints one CloudFormation stack output (empty if absent).
output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${3:-$AWS_REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null || true
}

# tf_output KEY: prints one Terraform output from infra/
tf_output() {
  (cd "$(dirname "${BASH_SOURCE[0]}")" && terraform output -raw "$1" 2>/dev/null || true)
}

# stack_exists STACK [REGION]
stack_exists() {
  aws cloudformation describe-stacks --stack-name "$1" --region "${2:-$AWS_REGION}" >/dev/null 2>&1
}

# cors_origins: the sites allowed to call the API: the CloudFront address and custom domain
# (once the frontend stack exists) plus CORS_ORIGINS_AWS.
cors_origins() {
  local candidates="" origins="" origin
  if stack_exists "$FRONTEND_STACK"; then
    candidates="$(output "$FRONTEND_STACK" AppUrl),$(output "$FRONTEND_STACK" CustomDomainUrl)"
  fi
  # Read line by line rather than word-splitting, so "*" (allow any origin) is not
  # expanded into file names.
  while IFS= read -r origin; do
    origin="${origin//[[:space:]]/}"
    [ -n "$origin" ] && origins="${origins:+$origins,}$origin"
  done < <(echo "$candidates,${CORS_ORIGINS_AWS:-}" | tr ',' '\n')
  echo "${origins:-http://localhost:5173}"
}

# update_backend_cors: points the backend's CORS_ORIGINS at the current frontend addresses.
# Every other backend parameter keeps its previous value.
update_backend_cors() {
  local origins
  origins="$(cors_origins)"
  echo "    CORS origins: $origins"
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides "CorsOrigins=$origins" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# app_urls: the origins the frontend runs on (local dev servers, CloudFront, custom domain);
# Cognito only redirects back (OAuth, e.g. Google) to <origin>/login for these.
app_urls() {
  local urls="http://localhost:5173,http://localhost:3000" url
  if stack_exists "$FRONTEND_STACK"; then
    for url in "$(output "$FRONTEND_STACK" AppUrl)" "$(output "$FRONTEND_STACK" CustomDomainUrl)"; do
      [ -n "$url" ] && [ "$url" != "None" ] && urls="$urls,$url"
    done
  fi
  echo "$urls"
}

# update_auth_urls: points the Cognito app client's redirect URLs at the current frontend
# addresses. Every other auth parameter (including the Google client) keeps its value.
update_auth_urls() {
  stack_exists "$AUTH_STACK" || return 0
  local urls
  urls="$(app_urls)"
  echo "    App URLs: $urls"
  aws cloudformation deploy \
    --stack-name "$AUTH_STACK" \
    --template-file infra/auth.yaml \
    --parameter-overrides "AppUrls=$urls" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
}

# require_auth_stack: exits with a hint when Cognito has not been deployed yet.
require_auth_stack() {
  if [ -n "$(tf_output UserPoolId)" ]; then
    return 0
  fi
  stack_exists "$AUTH_STACK" || {
    echo "Auth infrastructure not found in Terraform or CloudFormation; please deploy via HCP Terraform or make infra-plan." >&2
    exit 1
  }
}
