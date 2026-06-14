# ── Network ───────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "VPC ID — needed when adding VPC endpoints or peering connections in later stages."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (ALB + ECS tasks)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (Aurora)."
  value       = module.network.private_subnet_ids
}

output "alb_sg_id" {
  description = "ALB security group ID — referenced when creating the ALB listener in E2."
  value       = module.network.alb_sg_id
}

output "ecs_service_sg_id" {
  description = "ECS service security group ID — referenced in the ECS service definition in E2."
  value       = module.network.ecs_service_sg_id
}

output "db_sg_id" {
  description = "DB security group ID — referenced when creating the Aurora cluster in E3."
  value       = module.network.db_sg_id
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "github_actions_role_arn" {
  description = "ARN to set as role-to-assume in the GitHub Actions CI workflow."
  value       = module.iam.github_actions_role_arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN for the ECS task definition's executionRoleArn (E2)."
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "ARN for the ECS task definition's taskRoleArn (E2)."
  value       = module.iam.ecs_task_role_arn
}
