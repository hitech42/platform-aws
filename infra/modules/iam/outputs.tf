output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as the role-to-assume in the CI workflow."
  value       = aws_iam_role.github_deploy.arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role (used by the ECS agent). Pass to the task definition in E2."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role (used by the application container). Pass to the task definition in E2."
  value       = aws_iam_role.ecs_task.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or looked up). Useful for adding trust policies to future roles."
  value       = local.oidc_provider_arn
}
