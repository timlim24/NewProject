#!/usr/bin/env bash
# Deploys the backend (AWS Lambda) and its database (Aurora Serverless v2) to AWS. Run via
# `make deploy-backend`, which loads the AWS credentials and settings from .env.
set -euo pipefail

# Everything runs inside main so bash parses the whole file before starting. Otherwise
# editing the script (or a git pull) during a long deploy makes bash resume mid-file.
main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  require_auth_stack
  LAMBDA_MEMORY="${LAMBDA_MEMORY:-512}"
  PASSWORD_PARAM="/$PROJECT_NAME/db-password"

  # Git SHA, plus a timestamp when backend/ has uncommitted changes (ECR tags are immutable).
  TAG="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain -- backend)" ]; then
    TAG="$TAG-dirty-$(date +%Y%m%d%H%M%S)"
  fi

  account="$(aws sts get-caller-identity --query Account --output text)"
  echo "==> Deploying '$PROJECT_NAME' backend $TAG to account $account in $AWS_REGION"

  echo "==> [1/5] Database password ($PASSWORD_PARAM)"
  if aws ssm get-parameter --name "$PASSWORD_PARAM" >/dev/null 2>&1; then
    echo "    exists, keeping it"
  else
    # Hex only, so it can go into DATABASE_URL without escaping.
    aws ssm put-parameter --name "$PASSWORD_PARAM" --type SecureString \
      --value "$(openssl rand -hex 24)" >/dev/null
    echo "    created"
  fi
  # Idempotent, so parameters created before tagging was added get tagged too.
  aws ssm add-tags-to-resource --resource-type Parameter --resource-id "$PASSWORD_PARAM" \
    --tags "Key=$TAG_KEY,Value=$PROJECT_NAME"
  db_password="$(aws ssm get-parameter --name "$PASSWORD_PARAM" --with-decryption \
    --query Parameter.Value --output text)"

  echo "==> [2/5] Container registry ($ECR_STACK)"
  aws cloudformation deploy \
    --stack-name "$ECR_STACK" \
    --template-file infra/ecr.yaml \
    --parameter-overrides "ProjectName=$PROJECT_NAME" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  repository="$(output "$ECR_STACK" RepositoryUri)"
  image="$repository:$TAG"

  echo "==> [3/5] Build and push $image"
  if aws ecr describe-images --repository-name "$PROJECT_NAME-backend" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
    echo "    already in ECR, skipping"
  else
    # Lambda accepts only single-platform images without attestation manifests.
    docker build --platform linux/amd64 --provenance=false --sbom=false --tag "$image" backend
    aws ecr get-login-password | docker login --username AWS --password-stdin "${repository%%/*}"
    docker push "$image"
  fi

  echo "==> [4/5] Lambda + database ($BACKEND_STACK)"
  pool_id="$(output "$AUTH_STACK" UserPoolId)"
  client_id="$(output "$AUTH_STACK" UserPoolClientId)"
  # The function has no internet access, so it gets the token signing keys up front.
  jwks="$(curl -fsS "$(output "$AUTH_STACK" Issuer)/.well-known/jwks.json" \
    | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))')"
  echo "    Cognito: $pool_id (client $client_id)"
  # Includes the frontend's addresses once it is deployed, so a redeploy keeps them.
  cors="$(cors_origins)"
  echo "    CORS origins: $cors"
  echo "    The first run creates the Aurora database and takes about 10-15 minutes."
  aws cloudformation deploy \
    --stack-name "$BACKEND_STACK" \
    --template-file infra/backend.yaml \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectName=$PROJECT_NAME" \
      "ImageUri=$image" \
      "DBPassword=$db_password" \
      "MemorySize=$LAMBDA_MEMORY" \
      "CorsOrigins=$cors" \
      "CognitoUserPoolId=$pool_id" \
      "CognitoClientId=$client_id" \
      "CognitoJwks=$jwks" \
    --tags "${STACK_TAGS[@]}" \
    --no-fail-on-empty-changeset
  api_url="$(output "$BACKEND_STACK" ApiUrl)"

  # The first request after a deploy is a cold start: migrations check + app startup.
  echo "==> [5/5] Wait for $api_url/health"
  for _ in $(seq 24); do
    if curl -fsS --max-time 30 "$api_url/health" >/dev/null 2>&1; then
      echo
      echo "API:  $api_url"
      echo "Docs: $(output "$BACKEND_STACK" DocsUrl)"
      exit 0
    fi
    sleep 5
  done
  echo "Backend did not become healthy. Logs: aws logs tail /$PROJECT_NAME/backend --follow" >&2
  exit 1
}

main "$@"
