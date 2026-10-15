#!/usr/bin/env bash
set -e

# If invoked with a Lambda handler (e.g. app.reports.lambda_handler.handler)
if [ "$1" = "app.reports.lambda_handler.handler" ] || [[ "$1" == *".handler" ]]; then
    exec python3 -m app.reports.runner "$@"
fi

# Default behavior for backend API container
exec "$@"
