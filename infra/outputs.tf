# Everything the Makefile and the frontend build read (`terraform output -raw <name>`).

output "region" {
  value = data.aws_region.current.region
}

# --- Auth ---

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_issuer" {
  description = "Issuer (iss) of the pool's tokens; its JWKS is at <issuer>/.well-known/jwks.json."
  value       = "https://${aws_cognito_user_pool.main.endpoint}"
}

output "cognito_domain" {
  description = "Domain of the managed login page and the OAuth endpoints."
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

# --- Weekly report ---

output "reports_bucket_name" {
  value = aws_s3_bucket.reports.id
}

output "report_queue_url" {
  value = aws_sqs_queue.report_requests.url
}

output "report_dlq_url" {
  value = aws_sqs_queue.report_requests_dlq.url
}

output "report_builder_function_name" {
  value = aws_lambda_function.report_builder.function_name
}

output "report_mailer_function_name" {
  value = aws_lambda_function.report_mailer.function_name
}

output "report_schedule_name" {
  value = aws_scheduler_schedule.weekly_report.name
}

# --- Agenda parser ---

output "parser_url" {
  value = aws_lambda_function_url.parser.function_url
}

output "parser_function_name" {
  value = aws_lambda_function.parser.function_name
}
