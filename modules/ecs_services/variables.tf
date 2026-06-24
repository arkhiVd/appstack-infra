variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "region" {
  description = "AWS region (for awslogs + SDK region in containers)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (for ALB target groups)"
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN"
  type        = string
}

variable "alb_listener_arn" {
  description = "ALB HTTP listener ARN to attach path rules to"
  type        = string
}

variable "task_execution_role_arn" {
  description = "ECS task execution role ARN (ECR pull + CloudWatch logs)"
  type        = string
}

variable "ecr_repository_urls" {
  description = "Map of service name -> ECR repository URL"
  type        = map(string)
}

variable "image_tag" {
  description = "Image tag to deploy for every service"
  type        = string
  default     = "latest"
}

variable "worker_policy_arn" {
  description = "IAM policy ARN granting SQS consume/publish + PDF bucket read (from sqs_messaging)"
  type        = string
}

# ---- app configuration injected into every container -------------------------
variable "db_host" {
  description = "RDS hostname"
  type        = string
}

variable "db_name" {
  description = "Postgres database name"
  type        = string
  default     = "appstack"
}

variable "db_username" {
  description = "Postgres master username (matches rds_postgres var default)"
  type        = string
  default     = "tpadmin"
}

variable "db_password" {
  description = "Postgres master password"
  type        = string
  sensitive   = true
}

variable "opensearch_endpoint" {
  description = "OpenSearch VPC endpoint host (no scheme)"
  type        = string
}

variable "price_sync_queue_name" {
  description = "price-sync SQS queue name"
  type        = string
}

variable "pdf_ingest_queue_name" {
  description = "pdf-ingest SQS queue name"
  type        = string
}

variable "jwt_key" {
  description = "Shared JWT signing key (>=32 bytes)"
  type        = string
  sensitive   = true
}

variable "jwt_issuer" {
  description = "JWT issuer/audience"
  type        = string
  default     = "appstack"
}

variable "desired_count" {
  description = "Desired task count per service"
  type        = number
  default     = 1
}

variable "task_memory" {
  description = "Hard memory limit (MiB) per task. 10 tasks need a host with enough RAM (t3.micro=1GB fits ~3; use t3.medium for all 10)."
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "CloudWatch log retention"
  type        = number
  default     = 7
}
