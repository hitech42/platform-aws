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
  description = "IDs of the two private subnets (RDS PostgreSQL)."
  value       = module.network.private_subnet_ids
}

output "alb_sg_id" {
  description = "ALB security group ID — referenced when creating the ALB listener in E3."
  value       = module.network.alb_sg_id
}

output "ecs_service_sg_id" {
  description = "ECS service security group ID — referenced in the ECS service definition in E3."
  value       = module.network.ecs_service_sg_id
}

output "db_sg_id" {
  description = "DB security group ID — referenced when creating the RDS instance."
  value       = module.network.db_sg_id
}

# ── IAM ───────────────────────────────────────────────────────────────────────

output "github_actions_role_arn" {
  description = "ARN to set as role-to-assume in the GitHub Actions CI workflow."
  value       = module.iam.github_actions_role_arn
}

output "ecs_task_execution_role_arn" {
  description = "ARN for the ECS task definition's executionRoleArn (E3)."
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

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────

output "db_endpoint" {
  description = "Hostname of the RDS PostgreSQL instance. Used in DATABASE_URL (combine with db_port). Passed to the ECS task definition in E3."
  value       = module.data.db_endpoint
}

output "db_port" {
  description = "Database port (5432). Used when constructing DATABASE_URL and psql connections."
  value       = module.data.port
}

output "db_resource_id" {
  description = "RDS instance resource ID (db-XXXX). Used in the rds-db:connect IAM permission ARN and in DATABASE_URL for IAM auth token generation."
  value       = module.data.db_resource_id
}

output "db_arn" {
  description = "ARN of the RDS PostgreSQL instance."
  value       = module.data.db_arn
}

output "database_name" {
  description = "Default database name in the RDS instance."
  value       = module.data.database_name
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master credential secret (rds!* namespace). For break-glass/DBA access only — the app never reads this."
  value       = module.data.master_secret_arn
}

output "db_username" {
  description = "IAM-auth application DB username (platform_app). Used when constructing DATABASE_URL alongside an IAM-generated auth token."
  value       = module.data.db_username
}

# ── ECS / ECR / ALB ──────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL (without tag). Used by CI/CD: append :<commit-sha> for the immutable production tag."
  value       = module.ecs_service.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name. Set as ECS_CLUSTER in app-build-push.yml / app-deploy.yml."
  value       = module.ecs_service.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS service name. Set as ECS_SERVICE in app-deploy.yml."
  value       = module.ecs_service.ecs_service_name
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Service base URL: http://{alb_dns_name}/api/v1/"
  value       = module.ecs_service.alb_dns_name
}

output "log_group_name" {
  description = "CloudWatch log group name for ECS tasks (/ecs/cvs-platform-dev)."
  value       = module.ecs_service.log_group_name
}

# ── Observability ─────────────────────────────────────────────────────────────

output "alerts_topic_arn" {
  description = "SNS topic ARN for operational (service) alerts. Subscribe additional endpoints (PagerDuty, Slack) with aws_sns_topic_subscription resources, or via: aws sns subscribe --topic-arn <value> --protocol email --notification-endpoint your@email.com"
  value       = module.observability.alerts_topic_arn
}

output "dashboard_url" {
  description = "CloudWatch console URL for the CVSPlatformDev dashboard."
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.observability.dashboard_name}"
}

# ── Billing alarm ─────────────────────────────────────────────────────────────

output "billing_alarm_topic_arn" {
  description = "SNS topic ARN for the billing alarm. Subscribe your email: aws sns subscribe --topic-arn <this value> --protocol email --notification-endpoint your@email.com"
  value       = aws_sns_topic.billing_alarm.arn
}

# ── Convenience for scripts ───────────────────────────────────────────────────

output "aws_region" {
  description = "AWS region for this environment. Used by infra/scripts/setup-db-user.sh."
  value       = var.aws_region
}
