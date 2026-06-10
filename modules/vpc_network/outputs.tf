output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB + ECS EC2)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (RDS, Redis, OpenSearch)"
  value       = aws_subnet.private[*].id
}

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "ecs_sg_id" {
  description = "ECS hosts/containers security group ID"
  value       = aws_security_group.ecs.id
}

output "data_sg_id" {
  description = "Data tier security group ID (RDS/Redis/OpenSearch)"
  value       = aws_security_group.data.id
}
