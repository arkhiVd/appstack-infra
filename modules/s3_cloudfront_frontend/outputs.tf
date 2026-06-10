output "bucket_name" {
  description = "S3 bucket holding the admin panel build"
  value       = aws_s3_bucket.site.id
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain (https)"
  value       = aws_cloudfront_distribution.site.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation in CI/CD)"
  value       = aws_cloudfront_distribution.site.id
}
