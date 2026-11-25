# Part 3: producer -> Kinesis Data Streams -> Firehose -> S3 (Parquet, partitioned by event day)
#                                         \-> Lambda (tumbling window) -> SNS email alert
# Athena reads s3://<bucket>/stream/ through the Glue table stream_payments.
#
# The stream, Firehose and the consumer exist only while streaming_enabled = true (they bill per
# hour); the SNS topic, its subscription and the table stay, so the data stays queryable.

locals {
  stream_count = var.streaming_enabled ? 1 : 0
  stream_columns = {
    invoiceid     = "string"
    status        = "string"
    failurereason = "string"
    amount        = "bigint"
    finalamount   = "bigint"
    ccy           = "int"
    reference     = "string"
    createddate   = "string"
    modifieddate  = "string"
    receivedat    = "string"
    merchantid    = "string"
    merchantname  = "string"
    mcc           = "int"
    customerid    = "string"
    paymentmethod = "string"
    device        = "string"
    producedat    = "string"  # when the producer sent it (processing time of this replay)
    drill         = "boolean" # true only for events of the incident drill, see producer.py
  }
}

# --- Alerts (always on: free when idle, and the email subscription stays confirmed) ---

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- The table Firehose converts to, and Athena reads ---

resource "aws_glue_catalog_table" "stream" {
  name          = "stream_payments"
  database_name = aws_glue_catalog_database.payments.name
  table_type    = "EXTERNAL_TABLE"
  description   = "Payment events that came through Kinesis and Firehose, Parquet, partitioned by event day (modifiedDate)"

  parameters = {
    classification = "parquet"
    EXTERNAL       = "TRUE"
    # Partition projection: Athena computes the partitions, so no crawler or MSCK REPAIR after Firehose writes.
    "projection.enabled"          = "true"
    "projection.dt.type"          = "date"
    "projection.dt.format"        = "yyyy-MM-dd"
    "projection.dt.range"         = "2026-10-01,NOW"
    "projection.dt.interval"      = "1"
    "projection.dt.interval.unit" = "DAYS"
    "storage.location.template"   = "s3://${local.bucket}/stream/dt=$${dt}/"
  }

  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.bucket}/stream/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.stream_columns
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}

# --- Kinesis Data Stream ---

resource "aws_kinesis_stream" "payments" {
  count            = local.stream_count
  name             = "${var.name}-payments"
  shard_count      = 1 # 1 MB/s or 1,000 records/s in; the replay stays under it
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED" # $0.015 per shard-hour; on-demand would be $0.04 per stream-hour
  }
}

# --- Firehose: Kinesis -> S3, JSON converted to Parquet, partitioned by the event's day ---

resource "aws_cloudwatch_log_group" "firehose" {
  count             = local.stream_count
  name              = "/aws/kinesisfirehose/${var.name}-to-s3"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose" {
  count          = local.stream_count
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose[0].name
}

resource "aws_iam_role" "firehose" {
  name = "${var.name}-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = local.account } }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "read-stream-write-lake"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStream"
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
        Resource = "arn:aws:kinesis:${var.region}:${local.account}:stream/${var.name}-payments"
      },
      {
        Sid      = "DecryptStream"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "kinesis.${var.region}.amazonaws.com" }
        }
      },
      {
        Sid    = "WriteLake"
        Effect = "Allow"
        Action = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket",
        "s3:ListBucketMultipartUploads", "s3:PutObject"]
        Resource = [aws_s3_bucket.lake.arn, "${aws_s3_bucket.lake.arn}/stream/*", "${aws_s3_bucket.lake.arn}/stream-errors/*"]
      },
      {
        Sid      = "SchemaForParquet"
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
        Resource = ["arn:aws:glue:${var.region}:${local.account}:catalog", aws_glue_catalog_database.payments.arn, aws_glue_catalog_table.stream.arn]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = "logs:PutLogEvents"
        Resource = "arn:aws:logs:${var.region}:${local.account}:log-group:/aws/kinesisfirehose/${var.name}-to-s3:*"
      },
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "to_s3" {
  count       = local.stream_count
  name        = "${var.name}-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.payments[0].arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.lake.arn

    # Event-time partitions: an event lands in the day it happened (modifiedDate), not the day it
    # arrived, so the stream table lines up with the batch table's dt.
    prefix              = "stream/dt=!{partitionKeyFromQuery:dt}/"
    error_output_prefix = "stream-errors/!{firehose:error-output-type}/!{timestamp:yyyy-MM-dd}/"
    buffering_size      = 64 # MB; the minimum when converting to Parquet
    buffering_interval  = 60 # seconds: a file at least every minute

    dynamic_partitioning_configuration {
      enabled = true
    }

    processing_configuration {
      enabled = true

      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{dt: .modifiedDate[0:10]}"
        }
      }
    }

    data_format_conversion_configuration {
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.payments.name
        table_name    = aws_glue_catalog_table.stream.name
        role_arn      = aws_iam_role.firehose.arn
        region        = var.region
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose[0].name
      log_stream_name = aws_cloudwatch_log_stream.firehose[0].name
    }
  }
}

# --- The alert consumer: Lambda with a tumbling window on the same stream ---

data "archive_file" "alerter" {
  type        = "zip"
  source_file = "${path.module}/../alerter/handler.py"
  output_path = "${path.module}/.build/alerter.zip"
}

resource "aws_cloudwatch_log_group" "alerter" {
  name              = "/aws/lambda/${var.name}-alerter"
  retention_in_days = 14
}

resource "aws_iam_role" "alerter" {
  name = "${var.name}-alerter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alerter_kinesis" {
  role       = aws_iam_role.alerter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole"
}

resource "aws_iam_role_policy" "alerter" {
  name = "publish-alerts"
  role = aws_iam_role.alerter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "kinesis.${var.region}.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_lambda_function" "alerter" {
  function_name    = "${var.name}-alerter"
  role             = aws_iam_role.alerter.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.alerter.output_path
  source_code_hash = data.archive_file.alerter.output_base64sha256
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 60

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.alerter.name
  }

  environment {
    variables = {
      ALERT_TOPIC_ARN        = aws_sns_topic.alerts.arn
      FAILURE_RATE_THRESHOLD = tostring(var.failure_rate_threshold)
      ALERT_MIN_PAYMENTS     = tostring(var.alert_min_payments)
    }
  }
}

resource "aws_lambda_event_source_mapping" "alerter" {
  count                              = local.stream_count
  event_source_arn                   = aws_kinesis_stream.payments[0].arn
  function_name                      = aws_lambda_function.alerter.arn
  starting_position                  = "TRIM_HORIZON"
  batch_size                         = 1000
  maximum_batching_window_in_seconds = 5
  tumbling_window_in_seconds         = var.window_seconds
  maximum_retry_attempts             = 3
  bisect_batch_on_function_error     = true
}
