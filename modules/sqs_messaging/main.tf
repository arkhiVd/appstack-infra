# =============================================================================
# SQS Messaging Module
# Two decoupled pipelines (SQS free tier: 1M requests/month free):
#
#  1. price-sync : microservice publishes price/product changes here after a
#                  Postgres write. search-sync-worker (on ECS) consumes and
#                  updates OpenSearch. Decouples DB txn from search index.
#
#  2. pdf-ingest : Admin uploads a 5-6k item PDF to the S3 bucket. S3 emits an
#                  ObjectCreated event to this queue. pdf-ingest-worker (on ECS)
#                  parses the PDF and batch-inserts into Postgres.
#
# Each queue has a dead-letter queue (DLQ) for poison messages.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_id" "pdf_bucket" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# price-sync queue + DLQ
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "price_sync_dlq" {
  name                      = "${var.project_name}-price-sync-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "price_sync" {
  name                       = "${var.project_name}-price-sync"
  visibility_timeout_seconds = var.visibility_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.price_sync_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# -----------------------------------------------------------------------------
# pdf-ingest queue + DLQ
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "pdf_ingest_dlq" {
  name                      = "${var.project_name}-pdf-ingest-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "pdf_ingest" {
  name                       = "${var.project_name}-pdf-ingest"
  visibility_timeout_seconds = var.visibility_timeout

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.pdf_ingest_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# -----------------------------------------------------------------------------
# PDF ingestion bucket (private) — Admin Panel uploads PDFs here
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "pdf" {
  bucket = "${var.project_name}-pdf-ingest-${random_id.pdf_bucket.hex}"

  tags = {
    Name = "${var.project_name}-pdf-ingest"
  }
}

resource "aws_s3_bucket_public_access_block" "pdf" {
  bucket                  = aws_s3_bucket.pdf.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Allow the PDF bucket to send ObjectCreated events to the pdf-ingest queue
resource "aws_sqs_queue_policy" "pdf_ingest" {
  queue_url = aws_sqs_queue.pdf_ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3SendMessage"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.pdf_ingest.arn
        Condition = {
          ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.pdf.arn }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "pdf" {
  bucket = aws_s3_bucket.pdf.id

  # No suffix filter: bulk imports are CSV (and the worker dispatches by
  # extension anyway). Fire on every object creation, matching local LocalStack.
  queue {
    queue_arn = aws_sqs_queue.pdf_ingest.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.pdf_ingest]
}

# -----------------------------------------------------------------------------
# IAM policy for the ECS worker task role — consume queues + read PDF bucket.
# Attach this to the worker task role when the worker service is created.
# -----------------------------------------------------------------------------
resource "aws_iam_policy" "worker" {
  name        = "${var.project_name}-worker-sqs-s3"
  description = "Allow workers to consume SQS queues and read the PDF bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeQueues"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = [
          aws_sqs_queue.price_sync.arn,
          aws_sqs_queue.pdf_ingest.arn,
        ]
      },
      {
        Sid      = "PublishPriceSync"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.price_sync.arn]
      },
      {
        Sid      = "ReadPdfBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.pdf.arn}/*"]
      }
    ]
  })
}
