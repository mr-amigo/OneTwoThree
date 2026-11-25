output "bucket" {
  value = aws_s3_bucket.lake.id
}

output "athena_workgroup" {
  value = aws_athena_workgroup.lab8.name
}

output "glue_database" {
  value = aws_glue_catalog_database.payments.name
}

output "crawler" {
  value = aws_glue_crawler.payments.name
}

output "stream_name" {
  value = var.streaming_enabled ? aws_kinesis_stream.payments[0].name : ""
}

output "alert_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
