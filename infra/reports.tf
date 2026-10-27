# ------------------------------------------------------------------- S3 Bucket
resource "aws_s3_bucket" "reports" {
  bucket = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "DeleteOldReportsAfter90Days"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

# S3 Gateway VPC Endpoint for private subnets so report-builder in VPC can reach S3
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [local.route_table_id]

  tags = {
    PROJECT_NAME = var.project_name
  }
}

# ------------------------------------------------------------------ SQS Queues
resource "aws_sqs_queue" "reports_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_sqs_queue" "reports" {
  name                       = "${var.project_name}-report-requests"
  visibility_timeout_seconds = 360

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.reports_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    PROJECT_NAME = var.project_name
  }
}

# ------------------------------------------------------- EventBridge Scheduler
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-reports-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role_policy" "scheduler_sqs" {
  name = "SqsSendMessagePolicy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.reports.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "${var.project_name}-weekly-report"
  schedule_expression          = "cron(0 7 ? * MON *)"
  schedule_expression_timezone = "Europe/Kyiv"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.reports.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ week = null, source = "schedule" })
  }
}

# ------------------------------------------------------ Report Builder Lambda
resource "aws_cloudwatch_log_group" "builder" {
  name              = "/${var.project_name}/report-builder"
  retention_in_days = 7

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role" "builder" {
  name = "${var.project_name}-reports-builder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "builder_vpc" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "builder_s3" {
  name = "S3PutReports"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject"
      ]
      Resource = "${aws_s3_bucket.reports.arn}/reports/*"
    }]
  })
}

resource "aws_iam_role_policy" "builder_sqs" {
  name = "SqsConsumeReports"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ]
      Resource = aws_sqs_queue.reports.arn
    }]
  })
}

resource "aws_lambda_function" "builder" {
  function_name = "${var.project_name}-report-builder"
  package_type  = "Image"
  image_uri     = local.image_uri
  memory_size   = 512
  timeout       = 60
  role          = aws_iam_role.builder.arn

  image_config {
    command = ["app.reports.lambda_handler.handler"]
  }

  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [local.security_group_id]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.builder.name
  }

  environment {
    variables = {
      DATABASE_URL                 = local.database_url
      REPORTS_BUCKET               = aws_s3_bucket.reports.id
      AWS_LWA_PORT                 = "8080"
      AWS_LWA_READINESS_CHECK_PATH = "/"
      AWS_LWA_ASYNC_INIT           = "true"
    }
  }

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_lambda_event_source_mapping" "builder" {
  event_source_arn = aws_sqs_queue.reports.arn
  function_name    = aws_lambda_function.builder.arn
  batch_size       = 1
}

# ------------------------------------------------------- Report Mailer Lambda
resource "aws_cloudwatch_log_group" "mailer" {
  name              = "/${var.project_name}/report-mailer"
  retention_in_days = 7

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role" "mailer" {
  name = "${var.project_name}-reports-mailer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "mailer_basic" {
  role       = aws_iam_role.mailer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "mailer_s3" {
  name = "S3ReadReports"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.reports.arn}/reports/*"
    }]
  })
}

resource "aws_iam_role_policy" "mailer_ses" {
  name = "SesSendEmail"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

data "archive_file" "mailer_zip" {
  type        = "zip"
  output_path = "${path.module}/mailer_lambda.zip"

  source {
    content  = <<-PY
import json
import logging
import os
import urllib.parse
import boto3
from email.message import EmailMessage

logger = logging.getLogger("report_mailer")
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
sesv2 = boto3.client("sesv2")

def handler(event, context):
    logger.info("report-mailer triggered trigger=s3", extra={"trigger": "s3", "event": event})

    sender = os.environ.get("SENDER_EMAIL")
    recipients_raw = os.environ.get("RECIPIENT_EMAIL", "")
    recipients = [r.strip() for r in recipients_raw.split(",") if r.strip()]

    if not sender or not recipients:
        logger.error("Missing SENDER_EMAIL or RECIPIENT_EMAIL")
        return {"statusCode": 400, "body": "Missing email configuration"}

    records = event.get("Records", [])
    for record in records:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        logger.info("Processing S3 report bucket=%s key=%s", bucket, key)

        resp = s3.get_object(Bucket=bucket, Key=key)
        csv_bytes = resp["Body"].read()

        filename = key.split("/")[-1]
        week = filename.replace(".csv", "")

        msg = EmailMessage()
        msg["Subject"] = f"Weekly Meetings Report: {week}"
        msg["From"] = sender
        msg["To"] = ", ".join(recipients)
        msg.set_content(
            f"Hello,\n\nAttached is your weekly meetings report for {week}.\n\nBest regards,\nMeetings App"
        )
        msg.add_attachment(
            csv_bytes,
            maintype="text",
            subtype="csv",
            filename=filename
        )

        sesv2.send_email(
            FromEmailAddress=sender,
            Destination={"ToAddresses": recipients},
            Content={"Raw": {"Data": msg.as_bytes()}}
        )
        logger.info("Email delivered to %s for report %s", recipients, key)

    return {"statusCode": 200, "body": "Success"}
PY
    filename = "index.py"
  }
}

resource "aws_lambda_function" "mailer" {
  function_name    = "${var.project_name}-report-mailer"
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 30
  role             = aws_iam_role.mailer.arn
  filename         = data.archive_file.mailer_zip.output_path
  source_code_hash = data.archive_file.mailer_zip.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mailer.name
  }

  environment {
    variables = {
      SENDER_EMAIL    = var.sender_email
      RECIPIENT_EMAIL = var.recipient_email
    }
  }

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.mailer.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = data.aws_caller_identity.current.account_id
}
