#!/usr/bin/env bash
# Deploys the LLM agenda parser infrastructure (Lambda function outside VPC + public Function URL).
# Run via `make deploy-ai`.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  AI_STACK="$PROJECT_NAME-ai"

  # Ensure backend stack is deployed first
  if ! stack_exists "$BACKEND_STACK"; then
    echo "Error: Backend stack '$BACKEND_STACK' does not exist. Run 'make deploy-backend' first." >&2
    exit 1
  fi
  require_auth_stack

  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "==> Deploying '$AI_STACK' in account $account ($AWS_REGION)"

  # 1. Image URI: reuse current backend container image or IMAGE env var
  image="${IMAGE:-}"
  if [ -z "$image" ]; then
    image="$(aws lambda get-function --function-name "$PROJECT_NAME-backend" --query "Code.ImageUri" --output text 2>/dev/null || true)"
  fi
  if [ -z "$image" ] || [ "$image" = "None" ]; then
    repository="$(output "$ECR_STACK" RepositoryUri)"
    TAG="$(git rev-parse --short HEAD)"
    image="$repository:$TAG"
  fi
  echo "    Image URI: $image"

  user_pool_id="$(output "$AUTH_STACK" UserPoolId)"
  client_id="$(output "$AUTH_STACK" UserPoolClientId)"
  parser_model="${PARSER_MODEL:-anthropic.claude-opus-5-5}"

  # Resolve frontend URL for CORS if deployed
  cors_origins="http://localhost:5173,http://localhost:3000"
  if stack_exists "$FRONTEND_STACK"; then
    app_url="$(output "$FRONTEND_STACK" AppUrl 2>/dev/null || true)"
    if [ -n "$app_url" ] && [ "$app_url" != "None" ]; then
      cors_origins="$cors_origins,$app_url"
    fi
  fi
  if [ -n "${CORS_ORIGINS_AWS:-}" ]; then
    cors_origins="$cors_origins,$CORS_ORIGINS_AWS"
  fi

  echo "==> Deploying CloudFormation stack '$AI_STACK'..."
  aws cloudformation deploy \
    --stack-name "$AI_STACK" \
    --template-file infra/ai.yaml \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image" \
      "CognitoUserPoolId=$user_pool_id" \
      "CognitoClientId=$client_id" \
      "CorsOrigins=$cors_origins" \
      "ParserModel=$parser_model" \
    --capabilities CAPABILITY_IAM \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset

  parser_url="$(output "$AI_STACK" ParserUrl)"
  echo
  echo "==> Agenda parser deployed successfully!"
  echo "    Parser URL: $parser_url"
  echo "    Model:      $parser_model"
  echo

  # Save to .env for frontend builds
  if [ -f .env ]; then
    if grep -q "^VITE_AGENDA_PARSER_URL=" .env; then
      sed -i "s|^VITE_AGENDA_PARSER_URL=.*|VITE_AGENDA_PARSER_URL=$parser_url|" .env
    else
      echo "VITE_AGENDA_PARSER_URL=$parser_url" >> .env
    fi
    echo "Saved VITE_AGENDA_PARSER_URL to .env"
  fi
}

main "$@"
