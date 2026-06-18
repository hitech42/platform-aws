output "github_actions_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as the role-to-assume in the CI workflow."
  value       = aws_iam_role.github_deploy.arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role (used by the ECS agent to pull images and write logs)."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_execution_role_name" {
  description = "Name of the ECS task execution role. Used by aws_iam_role_policy.ecs_task_execution in envs/dev to attach the scoped ECR + CloudWatch inline policy without creating a module dependency cycle."
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role (used by the application container). Pass to the task definition in E3."
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_task_role_name" {
  description = "Name of the ECS task role. Used by the aws_iam_role_policy.ecs_task resource in envs/dev to attach the runtime policy without creating a module dependency cycle."
  value       = aws_iam_role.ecs_task.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or looked up). Useful for adding trust policies to future roles."
  value       = local.oidc_provider_arn
}

output "allowed_refs" {
  description = "GitHub ref patterns allowed to assume this environment's deploy role. Env-level tests assert on this to verify branch isolation between environments."
  value       = var.allowed_refs
}
