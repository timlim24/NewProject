# ----------------------------------------------------------------- Agenda Parser
resource "aws_cloudwatch_log_group" "ai_parser" {
  name              = "/${var.project_name}/agenda-parser"
  retention_in_days = 14

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_iam_role" "ai_parser" {
  name = "new-project-ai-ParserRole-Tc9aEaWSpEFu"

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

resource "aws_iam_role_policy_attachment" "ai_parser_basic" {
  role       = aws_iam_role.ai_parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ai_parser_bedrock" {
  name = "BedrockAccess"
  role = aws_iam_role.ai_parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock-mantle:CreateInference"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "ai_parser" {
  function_name = "${var.project_name}-agenda-parser"
  package_type  = "Image"
  image_uri     = local.image_uri
  memory_size   = 512
  timeout       = 30
  role          = aws_iam_role.ai_parser.arn

  image_config {
    command = ["app.ai.agenda_lambda.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.ai_parser.name
  }

  environment {
    variables = {
      PROJECT_NAME                 = var.project_name
      COGNITO_USER_POOL_ID         = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID            = aws_cognito_user_pool_client.main.id
      PARSER_MODEL                 = var.parser_model
      AWS_LWA_PORT                 = "8080"
      AWS_LWA_READINESS_CHECK_PATH = "/"
      AWS_LWA_ASYNC_INIT           = "true"
    }
  }

  tags = {
    PROJECT_NAME = var.project_name
  }
}

resource "aws_lambda_function_url" "ai_parser" {
  function_name      = aws_lambda_function.ai_parser.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = var.app_urls
    allow_methods = ["POST"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

resource "aws_lambda_permission" "ai_parser_url" {
  statement_id           = "new-project-ai-FunctionUrlPermission-90NfZ4deRZJm"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.ai_parser.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "ai_parser_invoke" {
  statement_id             = "new-project-ai-FunctionInvokePermission-gciaxYhdsEYg"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.ai_parser.function_name
  principal                = "*"
  invoked_via_function_url = true
}
