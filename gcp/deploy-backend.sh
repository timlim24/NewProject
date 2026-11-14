#!/usr/bin/env bash
# Builds the backend image, pushes it to Artifact Registry and rolls it out on Cloud Run.
# Run via `make gcp-deploy-backend` after gcp/ is applied. The service's configuration
# (database, secret, scaling) belongs to Terraform; this only changes the image.
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source gcp/common.sh

  service="$(gcp_output api_service)"
  repository="$(gcp_output image_repository)"

  # Git SHA, plus a timestamp when backend/ has uncommitted changes.
  TAG="$(git rev-parse --short HEAD)"
  if [ -n "$(git status --porcelain -- backend)" ]; then
    TAG="$TAG-dirty-$(date +%Y%m%d%H%M%S)"
  fi
  image="$repository:$TAG"

  echo "==> [1/3] Build and push $image"
  # --target app: the image without the Lambda Web Adapter.
  docker build --platform linux/amd64 --target app --tag "$image" backend
  gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
  docker push "$image"

  echo "==> [2/3] Deploy to Cloud Run ($service in $REGION)"
  # Migrations run when the container starts (alembic upgrade head), against Cloud SQL.
  gcloud run services update "$service" --region "$REGION" --image "$image" --quiet
  url="$(gcloud run services describe "$service" --region "$REGION" --format 'value(status.url)')"

  echo "==> [3/3] Wait for $url/api/health"
  for _ in $(seq 24); do
    if curl -fsS --max-time 30 "$url/api/health" >/dev/null 2>&1; then
      echo
      echo "API:  $url/api"
      echo "Docs: $url/api/docs"
      exit 0
    fi
    sleep 5
  done
  echo "Backend did not become healthy. Logs: gcloud run services logs read $service --region $REGION" >&2
  exit 1
}

main "$@"
