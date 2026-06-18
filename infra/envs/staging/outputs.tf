# ── Network ───────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "Staging VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (ALB + ECS tasks)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (RDS PostgreSQL)."
  value       = module.network.private_subnet_ids
}

output "alb_sg_id" {
  description = "ALB security group ID."
  value       = module.network.alb_sg_id
}

output "ecs_service_sg_id" {
  description = "ECS service security group ID."
  value       = module.network.ecs_service_sg_id
}

output "db_sg_id" {
  description = "DB security group ID."
  value       = module.network.db_sg_id
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "github_actions_role_arn" {
  description = "ARN of the staging GitHub Actions deploy role. Set as AWS_DEPLOY_ROLE_ARN in the GitHub 'staging' environment secret."
  value       = module.iam.github_actions_role_arn
}

output "github_actions_staging_role_arn" {
  description = "Alias for github_actions_role_arn — explicit name for cross-referencing from README setup instructions."
  value       = module.iam.github_actions_role_arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN for the ECS task definition's executionRoleArn."
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "ARN for the ECS task definition's taskRoleArn."
  value       = module.iam.ecs_task_role_arn
}

# ── KMS ───────────────────────────────────────────────────────────────────────

output "kms_key_arn" {
  description = "ARN of the staging platform CMK."
  value       = module.kms.kms_key_arn
}

output "kms_alias_arn" {
  description = "ARN of the staging KMS key alias."
  value       = module.kms.kms_alias_arn
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────

output "db_endpoint" {
  description = "Hostname of the staging RDS instance. Used in DATABASE_URL."
  value       = module.data.db_endpoint
}

output "db_port" {
  description = "Database port (5432)."
  value       = module.data.port
}

output "db_resource_id" {
  description = "Staging RDS resource ID (db-XXXX). Used in the rds-db:connect IAM permission ARN."
  value       = module.data.db_resource_id
}

output "db_arn" {
  description = "ARN of the staging RDS PostgreSQL instance."
  value       = module.data.db_arn
}

output "database_name" {
  description = "Default database name in the staging RDS instance."
  value       = module.data.database_name
}

output "master_secret_arn" {
  description = "ARN of the staging RDS-managed master credential secret. For break-glass/DBA access only."
  value       = module.data.master_secret_arn
}

output "db_username" {
  description = "IAM-auth application DB username (platform_app)."
  value       = module.data.db_username
}

# ── ECS / ECR / ALB ──────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "Staging ECR repository URL (cvs-platform-staging). CI/CD appends :<commit-sha> for the image tag."
  value       = module.ecs_service.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "Staging ECS cluster name (cvs-platform-staging)."
  value       = module.ecs_service.ecs_cluster_name
}

output "ecs_service_name" {
  description = "Staging ECS service name (cvs-platform-staging)."
  value       = module.ecs_service.ecs_service_name
}

output "task_definition_family" {
  description = "Staging ECS task definition family name (cvs-platform-staging)."
  value       = module.ecs_service.task_definition_family
}

output "alb_dns_name" {
  description = "Public DNS name of the staging ALB. Service base URL: http://{alb_dns_name}/api/v1/"
  value       = module.ecs_service.alb_dns_name
}

output "log_group_name" {
  description = "CloudWatch log group for staging ECS tasks (/ecs/cvs-platform-staging)."
  value       = module.ecs_service.log_group_name
}

# ── Observability ─────────────────────────────────────────────────────────────

output "alerts_topic_arn" {
  description = "SNS topic ARN for staging operational alerts (cvs-platform-staging-alerts)."
  value       = module.observability.alerts_topic_arn
}

output "dashboard_url" {
  description = "CloudWatch console URL for the CVSPlatformStaging dashboard."
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.observability.dashboard_name}"
}

# ── Convenience for scripts ───────────────────────────────────────────────────

output "aws_region" {
  description = "AWS region for this environment. Used by infra/scripts/setup-db-user.sh."
  value       = var.aws_region
}
