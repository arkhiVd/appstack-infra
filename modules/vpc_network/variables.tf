variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across (ALB needs >= 2)"
  type        = number
  default     = 2
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch (small cost; off by default for free tier)"
  type        = bool
  default     = false
}
