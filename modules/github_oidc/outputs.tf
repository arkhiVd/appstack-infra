output "plan_role_arn" {
  description = "ARN for AWS_PLAN_ROLE_ARN secret"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "ARN for AWS_APPLY_ROLE_ARN secret"
  value       = aws_iam_role.apply.arn
}
