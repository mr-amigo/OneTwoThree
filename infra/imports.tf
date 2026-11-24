# One-time adoption of the resources the three CloudFormation stacks created (Part 2, Step 3).
# The stacks were deleted with DeletionPolicy: Retain, so these resources belonged to nobody.
# Delete this file after the import has been applied.

# Auth (was meetings-cognito)
import {
  to = aws_cognito_user_pool.main
  id = "us-east-1_8hSfQWoBh"
}

import {
  to = aws_cognito_user_pool_domain.main
  id = "meetings-027824090051"
}

import {
  to = aws_cognito_managed_login_branding.main
  id = "us-east-1_8hSfQWoBh,3c781199-1d63-455a-8f46-27625d1ce6f1"
}

import {
  to = aws_cognito_identity_provider.google
  id = "us-east-1_8hSfQWoBh:Google"
}

import {
  to = aws_cognito_user_pool_client.web
  id = "us-east-1_8hSfQWoBh/441aupm53eff4u6vv8730vbtcm"
}

# Weekly report (was meetings-reports)
import {
  to = aws_sesv2_email_identity.sender
  id = nonsensitive(local.secret["report_sender_email"]) # from SSM: no personal address in Git
}

import {
  to = aws_vpc_endpoint.s3
  id = "vpce-07bfcf6d10af87941"
}

import {
  to = aws_cloudwatch_log_group.report_mailer
  id = "/aws/lambda/meetings-report-mailer"
}

import {
  to = aws_iam_role.report_mailer
  id = "meetings-reports-ReportMailerRole-wvOIQvikGMUf"
}

import {
  to = aws_iam_role_policy_attachment.report_mailer_logs
  id = "meetings-reports-ReportMailerRole-wvOIQvikGMUf/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

import {
  to = aws_iam_role_policy.report_mailer
  id = "meetings-reports-ReportMailerRole-wvOIQvikGMUf:ReadReportsAndSendEmail"
}

import {
  to = aws_lambda_function.report_mailer
  id = "meetings-report-mailer"
}

import {
  to = aws_lambda_permission.report_mailer_s3
  id = "meetings-report-mailer/meetings-reports-ReportMailerS3Permission-i6cugLEvlFSY"
}

import {
  to = aws_s3_bucket.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_s3_bucket_public_access_block.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_s3_bucket_ownership_controls.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_s3_bucket_lifecycle_configuration.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_s3_bucket_notification.reports
  id = "meetings-reports-027824090051-us-east-1"
}

import {
  to = aws_sqs_queue.report_requests_dlq
  id = "https://sqs.us-east-1.amazonaws.com/027824090051/meetings-report-requests-dlq"
}

import {
  to = aws_sqs_queue.report_requests
  id = "https://sqs.us-east-1.amazonaws.com/027824090051/meetings-report-requests"
}

import {
  to = aws_cloudwatch_log_group.report_builder
  id = "/aws/lambda/meetings-report-builder"
}

import {
  to = aws_iam_role.report_builder
  id = "meetings-reports-ReportBuilderRole-vfdmg7feUjdw"
}

import {
  to = aws_iam_role_policy_attachment.report_builder_vpc
  id = "meetings-reports-ReportBuilderRole-vfdmg7feUjdw/arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

import {
  to = aws_iam_role_policy.report_builder
  id = "meetings-reports-ReportBuilderRole-vfdmg7feUjdw:ConsumeQueueAndWriteReports"
}

import {
  to = aws_lambda_function.report_builder
  id = "meetings-report-builder"
}

import {
  to = aws_lambda_event_source_mapping.report_builder
  id = "55c88688-8954-4546-bceb-8fc5def76e17"
}

import {
  to = aws_iam_role.report_schedule
  id = "meetings-reports-ReportScheduleRole-Nrxn616gLanf"
}

import {
  to = aws_iam_role_policy.report_schedule
  id = "meetings-reports-ReportScheduleRole-Nrxn616gLanf:SendScheduledReportRequest"
}

import {
  to = aws_scheduler_schedule.weekly_report
  id = "default/meetings-weekly-report"
}

# Agenda parser (was meetings-ai)
import {
  to = aws_cloudwatch_log_group.parser
  id = "/aws/lambda/meetings-agenda-parser"
}

import {
  to = aws_iam_role.parser
  id = "meetings-ai-ParserRole-aZ8vbBGKtxUo"
}

import {
  to = aws_iam_role_policy_attachment.parser_logs
  id = "meetings-ai-ParserRole-aZ8vbBGKtxUo/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

import {
  to = aws_iam_role_policy.parser_bedrock
  id = "meetings-ai-ParserRole-aZ8vbBGKtxUo:BedrockInference"
}

import {
  to = aws_lambda_function.parser
  id = "meetings-agenda-parser"
}

import {
  to = aws_lambda_function_url.parser
  id = "meetings-agenda-parser"
}

import {
  to = aws_lambda_permission.parser_url
  id = "meetings-agenda-parser/meetings-ai-ParserFunctionUrlPermission-WK13umVNyb4T"
}

import {
  to = aws_lambda_permission.parser_invoke
  id = "meetings-agenda-parser/meetings-ai-ParserFunctionInvokePermission-4RhZcu7ZOb6O"
}

import {
  to = aws_budgets_budget.parser[0]
  id = "027824090051:meetings-agenda-parser-5usd"
}
