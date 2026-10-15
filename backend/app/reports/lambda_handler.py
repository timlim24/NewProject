from datetime import datetime, timedelta, timezone
import json
import logging
import os
from typing import Any

import boto3

from app.reports.weekly import build_weekly_report

logger = logging.getLogger("report_builder")
logger.setLevel(logging.INFO)
if not logger.handlers:
    handler_stdout = logging.StreamHandler()
    handler_stdout.setFormatter(
        logging.Formatter("[%(asctime)s] %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler_stdout)


def detect_trigger(event: dict[str, Any]) -> str:
    """Identify which event started the builder function."""
    if "Records" in event:
        # SQS event
        for record in event["Records"]:
            try:
                body = json.loads(record.get("body", "{}"))
                if isinstance(body, dict) and body.get("source") == "schedule":
                    return "schedule"
            except Exception:
                pass
        return "sqs"
    if event.get("source") == "schedule":
        return "schedule"
    return "direct"


def extract_week(event: dict[str, Any]) -> str:
    """Extract week from event payload or default to the previous ISO week."""
    week = None
    if "Records" in event:
        for record in event["Records"]:
            try:
                body = json.loads(record.get("body", "{}"))
                if isinstance(body, dict) and body.get("week"):
                    week = body["week"]
                    break
            except Exception:
                pass
    elif event.get("week"):
        week = event["week"]

    if not week:
        # Default to previous ISO week
        now = datetime.now(timezone.utc)
        prev = now - timedelta(days=7)
        iso_year, iso_week_num, _ = prev.isocalendar()
        week = f"{iso_year}-W{iso_week_num:02d}"

    return week


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """Lambda handler for report-builder."""
    trigger = detect_trigger(event)
    week = extract_week(event)

    # Required log line for item 5 of submission
    logger.info(
        "report-builder triggered trigger=%s week=%s",
        trigger,
        week,
        extra={"trigger": trigger, "week": week},
    )

    bucket = os.environ.get("REPORTS_BUCKET")
    if not bucket:
        raise ValueError("Missing REPORTS_BUCKET environment variable")

    # Generate CSV report
    csv_bytes = build_weekly_report(week)

    # Upload to S3 under reports/{week}.csv
    s3_key = f"reports/{week}.csv"
    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=bucket,
        Key=s3_key,
        Body=csv_bytes,
        ContentType="text/csv",
    )

    logger.info("Successfully generated and uploaded s3://%s/%s (%d bytes)", bucket, s3_key, len(csv_bytes))

    return {
        "statusCode": 200,
        "bucket": bucket,
        "key": s3_key,
        "week": week,
        "trigger": trigger,
    }
