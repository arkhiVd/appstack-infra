variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "appstack"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs (ALB needs >= 2)"
  type        = number
  default     = 2
}

variable "db_password" {
  description = "RDS master password. Supply via TF_VAR_db_password env var (never commit)."
  type        = string
  sensitive   = true
}

variable "jwt_key" {
  description = "Shared JWT signing key for the services (>=32 bytes). Supply via TF_VAR_jwt_key."
  type        = string
  sensitive   = true
  default     = "change-me-in-prod-please-32bytes-minimum-key!"
}

variable "image_tag" {
  description = "Container image tag to deploy for every ECS service (git SHA or 'latest')."
  type        = string
  default     = "latest"
}

variable "ecs_instance_type" {
  description = "ECS host instance type. t3.micro = free tier; use a few of them rather than one bigger paid instance."
  type        = string
  default     = "t3.micro"
}

variable "ecs_host_count" {
  description = "Number of ECS EC2 hosts. 4x t3.micro fits the 10 service tasks + the one-shot migrate task with placement headroom, while staying free-tier."
  type        = number
  default     = 4
}
