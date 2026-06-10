variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the cache subnet group"
  type        = list(string)
}

variable "security_group_id" {
  description = "Data-tier security group ID (ingress from ECS only)"
  type        = string
}

variable "node_type" {
  description = "Cache node type (cache.t3.micro = free tier 12mo)"
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}
