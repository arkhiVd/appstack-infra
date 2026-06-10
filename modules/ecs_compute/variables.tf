variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (ALB + ECS EC2 host)"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID (for ALB target group)"
  type        = string
}

variable "alb_sg_id" {
  description = "ALB security group ID"
  type        = string
}

variable "ecs_sg_id" {
  description = "ECS host/container security group ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for ECS host (t3.micro = free tier 750hrs)"
  type        = string
  default     = "t3.micro"
}

variable "asg_desired" {
  description = "Desired ECS EC2 host count"
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Max ECS EC2 host count"
  type        = number
  default     = 1
}
