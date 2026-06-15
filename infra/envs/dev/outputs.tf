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
  description = "ARN for the ECS task definition's taskRoleArn (E3)."
  value       = module.iam.ecs_task_role_arn
}

# ── KMS ───────────────────────────────────────────────────────────────────────

output "kms_key_arn" {
  description = "ARN of the platform CMK. Passed to ECS task definition environment variables in E3 and used by the app to encrypt/decrypt Secrets Manager entries."
  value       = module.kms.kms_key_arn
}

output "kms_alias_arn" {
  description = "ARN of the KMS key alias (alias/{project_name}-{environment})."
  value       = module.kms.kms_alias_arn
}

# ── Aurora ────────────────────────────────────────────────────────────────────

output "aurora_cluster_endpoint" {
  description = "Writer endpoint for DATABASE_URL (read-write connections). Passed to the ECS task definition in E3."
  value       = module.data.cluster_endpoint
}

output "aurora_cluster_reader_endpoint" {
  description = "Reader endpoint for read-only query routing (future use)."
  value       = module.data.cluster_reader_endpoint
}

output "aurora_cluster_resource_id" {
  description = "Aurora cluster resource ID (cluster-XXXX). Used in the rds-db:connect IAM permission ARN and in DATABASE_URL for IAM auth token generation."
  value       = module.data.cluster_resource_id
}

output "aurora_cluster_arn" {
  description = "ARN of the Aurora cluster. Required by infra/scripts/setup-db-user.sh (aws rds-data execute-statement)."
  value       = module.data.cluster_arn
}

output "aurora_database_name" {
  description = "Default database name in the Aurora cluster."
  value       = module.data.database_name
}

output "aurora_master_secret_arn" {
  description = "ARN of the Aurora-managed master credential secret (rds!* namespace). For break-glass/DBA access only — the app never reads this."
  value       = module.data.master_secret_arn
}

output "db_username" {
  description = "IAM-auth application DB username (platform_app). Used when constructing DATABASE_URL alongside an IAM-generated auth token."
  value       = module.data.db_username
}

# ── Billing alarm ─────────────────────────────────────────────────────────────

output "billing_alarm_topic_arn" {
  description = "SNS topic ARN for the billing alarm. Subscribe your email: aws sns subscribe --topic-arn <this value> --protocol email --notification-endpoint your@email.com"
  value       = aws_sns_topic.billing_alarm.arn
}

# ── Convenience for scripts ───────────────────────────────────────────────────

output "aws_region" {
  description = "AWS region for this environment. Used by infra/scripts/setup-db-user.sh as a fallback."
  value       = var.aws_region
}
