output "endpoint" {
  description = "OpenSearch VPC endpoint (HTTPS)"
  value       = aws_opensearch_domain.this.endpoint
}

output "domain_arn" {
  description = "OpenSearch domain ARN"
  value       = aws_opensearch_domain.this.arn
}

output "domain_name" {
  description = "OpenSearch domain name"
  value       = aws_opensearch_domain.this.domain_name
}
