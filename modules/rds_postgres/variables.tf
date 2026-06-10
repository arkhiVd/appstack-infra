variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "vpc_security_group_id" {
  description = "Data-tier security group ID (ingress from ECS only)"
  type        = string
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "appstack"
}

variable "db_username" {
  description = "Master username"
  type        = string
  default     = "tpadmin"
}

variable "db_password" {
  description = "Master password (supply via TF_VAR_db_password env var)"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  description = "RDS instance class (db.t3.micro = free tier 12mo)"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage in GiB (20 = free tier)"
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.14"
}

variable "backup_retention_period" {
  description = "Days of automated backups (free tier covers up to DB size)"
  type        = number
  default     = 7
}
