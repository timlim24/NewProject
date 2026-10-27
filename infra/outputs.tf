# Auth Outputs
output "Region" {
  value       = var.region
  description = "AWS Region"
}

output "UserPoolId" {
  value       = aws_cognito_user_pool.main.id
  description = "Cognito User Pool ID"
}

output "UserPoolClientId" {
  value       = aws_cognito_user_pool_client.main.id
  description = "Cognito App Client ID"
}

output "Domain" {
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
  description = "Cognito domain for OAuth redirects"
}

output "Issuer" {
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  description = "Issuer of the tokens"
}

output "GoogleEnabled" {
  value       = var.google_client_id != "" ? "true" : "false"
  description = "Whether Google OAuth is enabled"
}

# Reports Outputs
output "ReportsBucket" {
  value       = aws_s3_bucket.reports.id
  description = "Name of the S3 reports bucket"
}

output "ReportRequestsQueue" {
  value       = aws_sqs_queue.reports.name
  description = "Name of the SQS queue for report requests"
}

output "ReportRequestsQueueUrl" {
  value       = aws_sqs_queue.reports.url
  description = "URL of the SQS queue for report requests"
}

output "ReportRequestsDlq" {
  value       = aws_sqs_queue.reports_dlq.name
  description = "Name of the DLQ for failed report requests"
}

output "BuilderFunction" {
  value       = aws_lambda_function.builder.function_name
  description = "Report builder Lambda function name"
}

output "MailerFunction" {
  value       = aws_lambda_function.mailer.function_name
  description = "Report mailer Lambda function name"
}

# AI Outputs
output "ParserUrl" {
  value       = aws_lambda_function_url.ai_parser.function_url
  description = "Agenda Parser Lambda Function URL"
}

output "ParserFunctionName" {
  value       = aws_lambda_function.ai_parser.function_name
  description = "Agenda Parser Lambda function name"
}
