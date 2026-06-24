output "service_names" {
  description = "ECS service names created"
  value       = [for s in aws_ecs_service.this : s.name]
}

output "target_group_arns" {
  description = "Map of web service -> ALB target group ARN"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "task_role_arn" {
  description = "Shared application task role ARN"
  value       = aws_iam_role.task.arn
}
