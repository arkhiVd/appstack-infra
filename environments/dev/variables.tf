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
