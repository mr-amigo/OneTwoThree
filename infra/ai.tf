# Was infra/ai.yml (Lab 6): the agenda parser. A Lambda outside the VPC (it needs the internet for the
# LLM and no database), a public function URL that checks the Cognito ID token itself, an LLM chosen
# by parser_provider (OpenAI API, or Claude on Bedrock), and a $5 monthly budget alarm.

locals {
  parser_name = "${var.project_name}-agenda-parser"
}

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/aws/lambda/${local.parser_name}"
  retention_in_days = 14
}

resource "aws_iam_role" "parser" {
  # The name CloudFormation generated; kept so the role is imported, not replaced.
  name = "${var.project_name}-ai-ParserRole-aZ8vbBGKtxUo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "parser_logs" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Ready for parser_provider = bedrock / bedrock-converse without a code change.
resource "aws_iam_role_policy" "parser_bedrock" {
  name = "BedrockInference"
  role = aws_iam_role.parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Anthropic Messages API on Bedrock, only in the parser's region.
        Sid       = "MantleInference"
        Effect    = "Allow"
        Action    = "bedrock-mantle:CreateInference"
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region } }
      },
      {
        # Converse API: Anthropic models only, called directly or through this account's inference
        # profiles. A cross-region or global profile routes to other regions, hence "*" for the region.
        Sid    = "ConverseInference"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*:${local.account_id}:inference-profile/*anthropic.*",
        ]
      },
    ]
  })
}

resource "aws_lambda_function" "parser" {
  function_name = local.parser_name
  role          = aws_iam_role.parser.arn
  package_type  = "Image"
  image_uri     = local.image_uri
  architectures = [var.architecture]
  memory_size   = 512
  timeout       = 30

  image_config {
    command = ["app.ai.agenda_lambda.handler"]
  }

  environment {
    variables = {
      PARSER_PROVIDER      = var.parser_provider
      PARSER_MODEL         = var.parser_model
      OPENAI_API_KEY       = local.secret["openai_api_key"]
      COGNITO_REGION       = data.aws_region.current.region
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
      COGNITO_JWKS         = ""
    }
  }

  # The log group exists before the first invocation, so its retention applies from the start.
  depends_on = [aws_cloudwatch_log_group.parser]

  lifecycle {
    # New image tags are deployed by `make aws-lambda-images`, not by Terraform.
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE" # the handler verifies the Cognito ID token (401 otherwise)

  cors {
    allow_origins = local.cors_origins
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 86400
  }
}

# A public function URL needs both permissions: InvokeFunctionUrl, and InvokeFunction limited to calls
# that arrive through the URL.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "${var.project_name}-ai-ParserFunctionUrlPermission-WK13umVNyb4T"
  function_name          = aws_lambda_function.parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_invoke" {
  statement_id             = "${var.project_name}-ai-ParserFunctionInvokePermission-4RhZcu7ZOb6O"
  function_name            = aws_lambda_function.parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}

resource "aws_budgets_budget" "parser" {
  count = var.budget_enabled ? 1 : 0

  name         = "${local.parser_name}-5usd"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "5.0"
  limit_unit   = "USD"

  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [local.secret["budget_alert_email"]]
  }

  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [local.secret["budget_alert_email"]]
  }
}
