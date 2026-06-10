variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "subnet_id" {
  description = "Single private subnet ID (single-node domain, no zone awareness)"
  type        = string
}

variable "security_group_id" {
  description = "Data-tier security group ID (ingress 443 from ECS)"
  type        = string
}

variable "instance_type" {
  description = "OpenSearch node type (t3.small.search = free tier 12mo)"
  type        = string
  default     = "t3.small.search"
}

variable "engine_version" {
  description = "OpenSearch engine version"
  type        = string
  default     = "OpenSearch_2.11"
}

variable "ebs_volume_size" {
  description = "EBS volume per node in GiB (10 = free tier)"
  type        = number
  default     = 10
}
