# Was infra/reports.yaml (Lab 5): the event-driven weekly report.
# EventBridge Scheduler -> SQS (+ DLQ) -> builder Lambda (in the VPC, reads Aurora, writes S3 through
# the S3 gateway endpoint) -> S3 ObjectCreated -> mailer Lambda (outside the VPC, sends the CSV by SES).
#
# CloudFormation needed an explicit bucket name to break the bucket <-> permission <-> notification
# cycle. Here they are three resources (bucket, permission, notification) and the references order them.

locals {
  reports_bucket = "${var.project_name}-reports-${local.account_id}-${data.aws_region.current.region}"
  builder_name   = "${var.project_name}-report-builder"
  mailer_name    = "${var.project_name}-report-mailer"
}

# --- SES identities (the sandbox needs both sender and recipient verified) ---

resource "aws_sesv2_email_identity" "sender" {
  email_identity = local.secret["report_sender_email"]
}

resource "aws_sesv2_email_identity" "recipient" {
  # Whether the two addresses differ is not a secret, only the addresses are.
  count          = nonsensitive(local.secret["report_recipient_email"] == local.secret["report_sender_email"]) ? 0 : 1
  email_identity = local.secret["report_recipient_email"]
}

# --- S3 gateway endpoint: a free private path from the VPC's subnets to S3 ---

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = local.backend["VpcId"]
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  route_table_ids   = [local.backend["PrivateRouteTableId"]]
}

# --- Mailer Lambda (outside the VPC; triggered by S3 ObjectCreated on reports/*.csv) ---

resource "aws_cloudwatch_log_group" "report_mailer" {
  name              = "/aws/lambda/${local.mailer_name}"
  retention_in_days = var.report_log_retention_days
}

resource "aws_iam_role" "report_mailer" {
  # The name CloudFormation generated; kept so the role is imported, not replaced.
  name = "${var.project_name}-reports-ReportMailerRole-wvOIQvikGMUf"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_mailer_logs" {
  role       = aws_iam_role.report_mailer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "report_mailer" {
  name = "ReadReportsAndSendEmail"
  role = aws_iam_role.report_mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadReportCsvFromS3"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
      {
        Sid      = "SendReportEmailViaSes"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "arn:aws:ses:${data.aws_region.current.region}:${local.account_id}:identity/*"
      },
    ]
  })
}

# The mailer's code was inline in the template; now it is a file, zipped at plan time.
data "archive_file" "report_mailer" {
  type        = "zip"
  source_file = "${path.module}/lambda/report_mailer/index.py"
  output_path = "${path.module}/.build/report_mailer.zip"
}

resource "aws_lambda_function" "report_mailer" {
  function_name    = local.mailer_name
  role             = aws_iam_role.report_mailer.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.report_mailer.output_path
  source_code_hash = data.archive_file.report_mailer.output_base64sha256
  architectures    = [var.architecture]
  memory_size      = 256
  timeout          = 30

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_mailer.name
  }

  environment {
    variables = {
      REPORT_SENDER_EMAIL    = local.secret["report_sender_email"]
      REPORT_RECIPIENT_EMAIL = local.secret["report_recipient_email"]
    }
  }
}

resource "aws_lambda_permission" "report_mailer_s3" {
  statement_id   = "${var.project_name}-reports-ReportMailerS3Permission-i6cugLEvlFSY"
  function_name  = aws_lambda_function.report_mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_account = local.account_id
  source_arn     = aws_s3_bucket.reports.arn
}

# --- Reports bucket (private, 90-day lifecycle, notifies the mailer on reports/*.csv) ---

resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket

  # Every weekly report ever built is in here. Terraform refuses any plan that destroys it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports-after-90-days"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  # S3 tests the destination when the notification is saved, so the permission must exist first.
  depends_on = [aws_lambda_permission.report_mailer_s3]
}

# --- SQS queue + dead-letter queue (decouple schedule and manual requests from the builder) ---

resource "aws_sqs_queue" "report_requests_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600 # 14 days
  max_message_size          = 1048576 # the SQS default (1 MiB); the provider's default is still 256 KiB
}

resource "aws_sqs_queue" "report_requests" {
  name                       = "${var.project_name}-report-requests"
  visibility_timeout_seconds = 360     # 6x the builder's 60-second timeout
  max_message_size           = 1048576 # the SQS default (1 MiB)

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# --- Builder Lambda (the backend image, in the VPC, writes the CSV to S3) ---

resource "aws_cloudwatch_log_group" "report_builder" {
  name              = "/aws/lambda/${local.builder_name}"
  retention_in_days = var.report_log_retention_days
}

resource "aws_iam_role" "report_builder" {
  # The name CloudFormation generated; kept so the role is imported, not replaced.
  name = "${var.project_name}-reports-ReportBuilderRole-vfdmg7feUjdw"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "report_builder_vpc" {
  role       = aws_iam_role.report_builder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "report_builder" {
  name = "ConsumeQueueAndWriteReports"
  role = aws_iam_role.report_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeReportRequestsQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.report_requests.arn
      },
      {
        Sid      = "PutReportCsvToS3"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.reports.arn}/reports/*"
      },
    ]
  })
}

resource "aws_lambda_function" "report_builder" {
  function_name = local.builder_name
  role          = aws_iam_role.report_builder.arn
  package_type  = "Image"
  image_uri     = local.image_uri
  architectures = [var.architecture]
  memory_size   = 512
  timeout       = 60

  image_config {
    command = ["app.reports.lambda_handler.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.report_builder.name
  }

  vpc_config {
    subnet_ids         = split(",", local.backend["PrivateSubnetIds"])
    security_group_ids = [local.backend["BackendSecurityGroupId"]]
  }

  environment {
    variables = {
      DB_HOST        = local.backend["DbEndpoint"]
      DB_PORT        = local.backend["DbPort"]
      DB_NAME        = local.backend["DbName"]
      DB_USER        = local.backend["DbUsername"]
      DB_PASSWORD    = jsondecode(data.aws_secretsmanager_secret_version.db.secret_string)["password"]
      DB_NULL_POOL   = "true"
      REPORTS_BUCKET = aws_s3_bucket.reports.id
      FAIL_ON_WEEK   = var.report_fail_on_week
    }
  }

  # The builder reaches S3 only through the gateway endpoint (no NAT).
  depends_on = [aws_vpc_endpoint.s3]

  lifecycle {
    # New image tags are deployed by `make aws-lambda-images`, not by Terraform.
    ignore_changes = [image_uri]
  }
}

resource "aws_lambda_event_source_mapping" "report_builder" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.report_builder.arn
  batch_size       = 1
  enabled          = true
}

# --- EventBridge Scheduler (Monday 07:00 Europe/Kyiv -> SQS queue, or the builder directly) ---

resource "aws_iam_role" "report_schedule" {
  # The name CloudFormation generated; kept so the role is imported, not replaced.
  name = "${var.project_name}-reports-ReportScheduleRole-Nrxn616gLanf"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "report_schedule" {
  name = "SendScheduledReportRequest"
  role = aws_iam_role.report_schedule.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendToReportRequestsQueue"
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.report_requests.arn
      },
      {
        Sid      = "InvokeReportBuilderLambda"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.report_builder.arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "${var.project_name}-weekly-report"
  description                  = "Weekly meetings report schedule (Monday 07:00 Europe/Kyiv)"
  schedule_expression          = var.report_schedule_expression
  schedule_expression_timezone = var.report_schedule_timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.report_schedule_target == "LAMBDA" ? aws_lambda_function.report_builder.arn : aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.report_schedule.arn
    # The exact string the queue has always received (jsonencode would reorder the keys).
    input = "{\"trigger\": \"schedule\", \"source\": \"aws.scheduler\"}"
  }
}
