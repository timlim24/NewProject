#!/usr/bin/env bash
# Builds the frontend against the backend's Lambda function URL and deploys it to
# S3 + CloudFront. Run via `make deploy-frontend` after `make deploy-backend`.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  stack_exists "$BACKEND_STACK" || { echo "Stack $BACKEND_STACK not found; run make deploy-backend first." >&2; exit 1; }
  require_auth_stack
  api_base_url="$(output "$BACKEND_STACK" ApiBaseUrl)"
  parser_url="$(output "$PROJECT_NAME-ai" ParserUrl 2>/dev/null || true)"
  [ -z "$parser_url" ] && parser_url="$(tf_output ParserUrl)"

  user_pool_id="$(output "$AUTH_STACK" UserPoolId 2>/dev/null || true)"
  [ -z "$user_pool_id" ] && user_pool_id="$(tf_output UserPoolId)"

  client_id="$(output "$AUTH_STACK" UserPoolClientId 2>/dev/null || true)"
  [ -z "$client_id" ] && client_id="$(tf_output UserPoolClientId)"

  cognito_domain="$(output "$AUTH_STACK" Domain 2>/dev/null || true)"
  [ -z "$cognito_domain" ] && cognito_domain="$(tf_output Domain)"

  google_enabled="$(output "$AUTH_STACK" GoogleEnabled 2>/dev/null || true)"
  [ -z "$google_enabled" ] && google_enabled="$(tf_output GoogleEnabled)"

  echo "==> [1/6] Build the frontend (API: $api_base_url, Parser: $parser_url)"
  (cd frontend && npm ci && \
    VITE_API_URL="$api_base_url" \
    VITE_AGENDA_PARSER_URL="$parser_url" \
    COGNITO_USER_POOL_ID="$user_pool_id" \
    COGNITO_CLIENT_ID="$client_id" \
    COGNITO_DOMAIN="$cognito_domain" \
    COGNITO_GOOGLE_ENABLED="$google_enabled" \
    npm run build)

  echo "==> [2/6] S3 bucket + CloudFront ($FRONTEND_STACK)"
  echo "    The first run creates the CloudFront distribution and takes about 5 minutes."
  # A custom domain added with `make add-domain` is kept: parameters that are not
  # overridden keep their previous values.
  aws cloudformation deploy \
    --stack-name "$FRONTEND_STACK" \
    --template-file infra/frontend.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  bucket="$(output "$FRONTEND_STACK" BucketName)"
  distribution="$(output "$FRONTEND_STACK" DistributionId)"

  echo "==> [3/6] Allow the frontend to call the API ($BACKEND_STACK)"
  update_backend_cors

  echo "==> [4/6] Allow Cognito to redirect back to the frontend ($AUTH_STACK)"
  update_auth_urls

  echo "==> [5/6] Upload to s3://$bucket"
  # Hashed assets never change, so browsers may cache them forever; everything else is revalidated.
  aws s3 sync frontend/dist/assets "s3://$bucket/assets" --delete \
    --cache-control "public, max-age=31536000, immutable"
  aws s3 sync frontend/dist "s3://$bucket" --delete --exclude "assets/*" \
    --cache-control "no-cache"

  echo "==> [6/6] Invalidate the CloudFront cache"
  # "/*" counts as a single path against the 1,000 free invalidation paths per month.
  invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
    --paths "/*" --query Invalidation.Id --output text)"
  aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

  echo
  echo "App: $(output "$FRONTEND_STACK" AppUrl)"
  custom_url="$(output "$FRONTEND_STACK" CustomDomainUrl)"
  [ -z "$custom_url" ] || echo "     $custom_url"
  echo "API: $api_base_url/api"
  if [ -n "${DOMAIN_NAME:-}" ] && [ "$custom_url" != "https://$DOMAIN_NAME" ]; then
    echo
    echo "DOMAIN_NAME=$DOMAIN_NAME in .env is not attached yet; run make add-domain."
  fi
}

main "$@"
