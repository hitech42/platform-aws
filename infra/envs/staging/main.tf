# Staging environment — deployed from the `staging` branch. Promotes from `develop`.
# Do not edit resource names manually — they are derived from the environment variable.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

module "network" {
  source = "../../modules/network"

  project_name = var.project_name
  environment  = var.environment
  vpc_cidr     = var.vpc_cidr
  # public_subnet_cidrs and private_subnet_cidrs use module defaults:
  #   public:  ["10.0.0.0/24", "10.0.1.0/24"]
  #   private: ["10.0.2.0/24", "10.0.3.0/24"]
  # Staging gets its own VPC so the same CIDRs as dev are safe (no peering).
}

# ── IAM roles ─────────────────────────────────────────────────────────────────
#
# create_oidc_provider=false: the GitHub OIDC provider is account-wide and was
# created by the dev environment apply. Staging looks it up via data source.
#
# allowed_refs restricts the deploy role to the staging branch only — the
# develop branch cannot assume this role, preventing cross-environment deploys.

module "iam" {
  source = "../../modules/iam"

  project_name         = var.project_name
  environment          = var.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  create_oidc_provider = var.create_oidc_provider # false — already exists
  allowed_refs         = var.allowed_refs         # ["refs/heads/staging"]
  allowed_environments = ["staging"]              # app-deploy.yml declares environment: staging
  state_bucket_name    = var.state_bucket_name
  ecr_repository_name  = "${var.project_name}-${var.environment}" # "cvs-platform-staging"
}

# ── KMS customer-managed key ──────────────────────────────────────────────────

module "kms" {
  source = "../../modules/kms"

  project_name      = var.project_name
  environment       = var.environment
  ecs_task_role_arn = module.iam.ecs_task_role_arn
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────
#
# deletion_protection=true and skip_final_snapshot=false protect staging data:
# - A `terraform destroy` will fail until deletion_protection is explicitly
#   set to false in a prior apply.
# - A final snapshot is retained so data can be recovered if needed.
# The terraform-destroy.yml workflow handles the pre-destroy flip automatically.

module "data" {
  source = "../../modules/data"

  project_name       = var.project_name
  environment        = var.environment
  kms_key_arn        = module.kms.kms_key_arn
  private_subnet_ids = module.network.private_subnet_ids
  db_sg_id           = module.network.db_sg_id
  db_name            = var.db_name
  db_username        = var.db_username

  deletion_protection = true  # requires a second apply to remove before destroy
  skip_final_snapshot = false # retain last backup on destroy
  # engine_version (16), instance_class (db.t4g.micro), multi_az (false) use module defaults
}

# ── ECS service ───────────────────────────────────────────────────────────────
#
# ecr_repository_name="cvs-platform-staging": each environment has an isolated
# ECR repo so a staging push cannot accidentally overwrite a dev image.

module "ecs_service" {
  source = "../../modules/ecs-service"

  project_name = var.project_name
  environment  = var.environment

  kms_key_arn = module.kms.kms_key_arn

  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.network.alb_sg_id
  ecs_service_sg_id = module.network.ecs_service_sg_id

  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  ecs_task_role_arn           = module.iam.ecs_task_role_arn

  db_endpoint = module.data.db_endpoint
  db_username = var.db_username
  db_name     = var.db_name

  ecr_repository_name = "${var.project_name}-${var.environment}" # "cvs-platform-staging"
  log_retention_days  = 14                                       # longer than dev's 7 days
  # desired_count (1), task_cpu (256), task_memory (512), app_port (8000), ecr_image_count_limit (10) use module defaults
}

# ── ECS task execution role runtime policy ────────────────────────────────────
#
# Same structure as envs/dev — scoped to staging's ECR repo and log group.

resource "aws_iam_role_policy" "ecs_task_execution" {
  name = "${local.prefix}-ecs-task-execution-policy"
  role = module.iam.ecs_task_execution_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPullImage"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = module.ecs_service.ecr_repository_arn
      },
      {
        Sid    = "CloudWatchLogWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${module.ecs_service.log_group_arn}:*"
      },
      {
        Sid    = "KMSDecryptForECR"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = module.kms.kms_key_arn
      },
    ]
  })
}

# ── ECS task role runtime policy ──────────────────────────────────────────────
#
# Same structure as envs/dev — scoped to staging's RDS instance and KMS key.

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.prefix}-ecs-task-policy"
  role = module.iam.ecs_task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RDSIAMAuth"
        Effect   = "Allow"
        Action   = ["rds-db:connect"]
        Resource = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${module.data.db_resource_id}/${var.db_username}"
      },
      {
        Sid    = "SecretsManagerAppSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:platform/*"
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = module.kms.kms_key_arn
      },
    ]
  })
}

# ── Observability ─────────────────────────────────────────────────────────────

module "observability" {
  source = "../../modules/observability"

  project_name = var.project_name
  environment  = var.environment
  alert_email  = var.alert_email

  ecs_cluster_name = module.ecs_service.ecs_cluster_name
  ecs_service_name = module.ecs_service.ecs_service_name

  alb_arn_suffix = module.ecs_service.alb_arn_suffix
  tg_arn_suffix  = module.ecs_service.tg_arn_suffix

  rds_instance_identifier = module.data.db_instance_identifier

  log_group_name = module.ecs_service.log_group_name
}

# Note: no billing alarm in staging. The billing alarm in envs/dev monitors
# account-level EstimatedCharges (AWS/Billing namespace) — a second alarm in
# staging would watch the same metric and fire simultaneously, creating noise.
# One billing alarm per AWS account is sufficient. See DECISIONS.md.
