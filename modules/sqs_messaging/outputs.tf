output "price_sync_queue_url" {
  description = "URL of the price-sync queue (microservices publish here)"
  value       = aws_sqs_queue.price_sync.id
}

output "price_sync_queue_arn" {
  value = aws_sqs_queue.price_sync.arn
}

output "pdf_ingest_queue_url" {
  description = "URL of the pdf-ingest queue (S3 events land here)"
  value       = aws_sqs_queue.pdf_ingest.id
}

output "pdf_ingest_queue_arn" {
  value = aws_sqs_queue.pdf_ingest.arn
}

output "pdf_bucket_name" {
  description = "S3 bucket admins upload PDFs to"
  value       = aws_s3_bucket.pdf.id
}

output "worker_policy_arn" {
  description = "IAM policy ARN to attach to the ECS worker task role"
  value       = aws_iam_policy.worker.arn
}
