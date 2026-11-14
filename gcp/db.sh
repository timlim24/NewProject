#!/usr/bin/env bash
# Starts, stops or shows the Cloud SQL instance: make gcp-db-stop / gcp-db-start / gcp-db-status.
# Stopped, it bills only its 10 GB of storage ($1.70/month) instead of $9.40.
set -euo pipefail

cd "$(dirname "$0")/.."
source gcp/common.sh
instance="$(gcp_output db_instance)"

case "${1:-status}" in
  stop)
    gcloud sql instances patch "$instance" --activation-policy=NEVER --quiet
    echo "Stopped $instance. The API on Cloud Run fails until 'make gcp-db-start'." ;;
  start)
    gcloud sql instances patch "$instance" --activation-policy=ALWAYS --quiet
    echo "Started $instance." ;;
  status)
    gcloud sql instances describe "$instance" \
      --format 'table(name, state, settings.activationPolicy, settings.tier, region)' ;;
  *)
    echo "Usage: $0 start|stop|status" >&2; exit 1 ;;
esac
