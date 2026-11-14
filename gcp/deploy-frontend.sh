#!/usr/bin/env bash
# Builds the frontend and deploys it to Firebase Hosting. Firebase rewrites /api/** to the
# Cloud Run service (frontend/firebase.json), so the app and the API share one origin: no
# API URL in the bundle and no CORS. Sign-in (Cognito) and the agenda parser stay on AWS.
set -euo pipefail

FIREBASE="npx --yes firebase-tools@15.34.2"

main() {
  cd "$(dirname "$0")/.."
  source gcp/common.sh

  pool_id="$(aws_output UserPoolId)"
  client_id="$(aws_output UserPoolClientId)"
  cognito_domain="$(aws_output Domain)"
  google_enabled="$(aws_output GoogleEnabled)"
  parser_url="$(aws_output ParserUrl)"
  [ -n "$pool_id" ] || { echo "No outputs from infra/ (Cognito); run 'terraform login' and 'cd infra && terraform init'." >&2; exit 1; }

  echo "==> [1/2] Build the frontend (API: same origin /api, Cognito: $pool_id)"
  (cd frontend && npm ci && \
    VITE_API_URL="" \
    VITE_AGENDA_PARSER_URL="$parser_url" \
    COGNITO_USER_POOL_ID="$pool_id" \
    COGNITO_CLIENT_ID="$client_id" \
    COGNITO_DOMAIN="$cognito_domain" \
    COGNITO_GOOGLE_ENABLED="$google_enabled" \
    npm run build)

  echo "==> [2/2] Deploy to Firebase Hosting ($PROJECT_ID)"
  (cd frontend && $FIREBASE deploy --only hosting --project "$PROJECT_ID" --non-interactive)

  echo
  echo "App: https://$PROJECT_ID.web.app"
  echo "Google sign-in and the parser need https://$PROJECT_ID.web.app in app_urls of infra/terraform.tfvars."
}

main "$@"
