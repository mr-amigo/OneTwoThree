# Part 2: our copy of the dataset, the Athena workgroup and the Glue catalog.
#
# s3://<bucket>/payments/dt=YYYY-MM-DD/events.jsonl   raw JSON Lines, copied from the course bucket
# s3://<bucket>/curated/payments/dt=.../              Parquet written by the CTAS query (Part 2, query 7)
# s3://<bucket>/stream/dt=.../                        Parquet written by Firehose (Part 3)
# s3://<bucket>/athena-results/                       query results, kept 14 days

resource "aws_s3_bucket" "lake" {
  bucket        = local.bucket
  force_destroy = true # a lab sandbox: every object can be copied or recomputed again
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

  rule {
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 14
    }
  }
}

resource "aws_athena_workgroup" "lab8" {
  name          = var.name
  description   = "Lab 8: payments lake. Results in s3://${local.bucket}/athena-results/"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = false # CTAS writes Parquet to curated/ (its own external_location)
    publish_cloudwatch_metrics_enabled = true
    # A runaway query over the whole lake stops at 10 GB ($0.05) instead of billing on.
    bytes_scanned_cutoff_per_query = 10 * 1024 * 1024 * 1024

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${local.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_glue_catalog_database" "payments" {
  name        = "lab8_payments"
  description = "Lab 8: payment webhook events. Tables: payment_events (by hand), crawled_payments (Glue crawler), stream_payments (Firehose)"
}

# --- Way B: a Glue crawler over the same raw prefix ---

resource "aws_iam_role" "crawler" {
  name = "${var.name}-glue-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "crawler_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "crawler_read_raw" {
  name = "read-raw-payments"
  role = aws_iam_role.crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.lake.arn}/payments/*"
      },
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.lake.arn
        Condition = { StringLike = { "s3:prefix" = ["payments/*", "payments"] } }
      },
    ]
  })
}

resource "aws_glue_crawler" "payments" {
  name          = "${var.name}-payments"
  description   = "Way B: infer the schema of s3://${local.bucket}/payments/"
  database_name = aws_glue_catalog_database.payments.name
  role          = aws_iam_role.crawler.arn
  table_prefix  = "crawled_"

  s3_target {
    path = "s3://${local.bucket}/payments/"
  }

  # Run on demand only (no schedule); keep the table if the data disappears.
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version  = 1
    Grouping = { TableGroupingPolicy = "CombineCompatibleSchemas" }
  })
}
