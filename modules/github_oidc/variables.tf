variable "project_name" {
  description = "Project name prefix for role names"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo in owner/name form, e.g. arkhiVd/appstack-infra"
  type        = string
}

variable "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform state (for plan-role read + lock access)"
  type        = string
}

variable "lock_table_arn" {
  description = "ARN of the DynamoDB state-lock table"
  type        = string
}
