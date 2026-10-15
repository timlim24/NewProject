#!/usr/bin/env bash
# Generates a weekly report on demand by sending a message to the SQS queue.
# Usage: make report-now WEEK=2026-W41
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  source infra/common.sh

  WEEK="${1:?Usage: make report-now WEEK=YYYY-Wnn}"
  REPORTS_STACK="$PROJECT_NAME-reports"

  echo "==> Triggering on-demand report for week $WEEK"
  queue_url="$(output "$REPORTS_STACK" ReportRequestsQueueUrl)"
  if [ -z "$queue_url" ] || [ "$queue_url" = "None" ]; then
    queue_url="$(aws sqs get-queue-url --queue-name "$PROJECT_NAME-report-requests" --query QueueUrl --output text)"
  fi

  echo "    Queue URL: $queue_url"
  aws sqs send-message \
    --queue-url "$queue_url" \
    --message-body "{\"week\": \"$WEEK\", \"source\": \"manual\"}"

  echo "==> Message sent successfully! Report will be built and emailed shortly."
  echo "    Check builder logs: aws logs tail /$PROJECT_NAME/report-builder --follow"
}

main "$@"
