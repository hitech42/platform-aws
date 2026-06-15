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
  # app_port uses module default: 8000
}

# ── IAM roles ─────────────────────────────────────────────────────────────────
#
# Dependency order: iam → kms → data.
# The iam module creates role shells; the ECS task runtime policy is attached
# below (not in the module) to avoid the iam→data→kms→iam dependency cycle.

module "iam" {
  source = "../../modules/iam"

  project_name         = var.project_name
  environment          = var.environment
  github_org           = var.github_org
  github_repo          = var.github_repo
  create_oidc_provider = var.create_oidc_provider
  allowed_refs         = var.allowed_refs
  state_bucket_name    = var.state_bucket_name
  # oidc_thumbprints uses module default (known GitHub OIDC cert thumbprints)
}

# ── KMS customer-managed key ──────────────────────────────────────────────────
#
# Depends on iam (for ecs_task_role_arn in the key policy).
# Used by: Aurora storage, Aurora master credential in Secrets Manager,
# application secrets in the platform/* namespace, CloudWatch logs (E4).

module "kms" {
  source = "../../modules/kms"

  project_name      = var.project_name
  environment       = var.environment
  ecs_task_role_arn = module.iam.ecs_task_role_arn
}

# ── Aurora PostgreSQL Serverless v2 ───────────────────────────────────────────
#
# Depends on kms (for kms_key_arn) and network (for private_subnet_ids, db_sg_id).
# The db_sg already scopes inbound to ecs_service_sg on port 5432 only.

module "data" {
  source = "../../modules/data"

  project_name       = var.project_name
  environment        = var.environment
  kms_key_arn        = module.kms.kms_key_arn
  private_subnet_ids = module.network.private_subnet_ids
  db_sg_id           = module.network.db_sg_id
  db_name            = var.db_name
  db_username        = var.db_username
  # engine_version (16.4), min_capacity (0.5), max_capacity (1.0),
  # enable_http_endpoint (true) use module defaults
}

# ── ECS task role runtime policy ──────────────────────────────────────────────
#
# Lives here rather than in the iam module to break the dependency cycle:
#   iam (creates task role) → kms (key policy references task role ARN)
#   → data (needs kms_key_arn) → [this policy needs data.cluster_resource_id]
#
# All three permissions are scoped to the minimum necessary resource:
#   rds-db:connect   → exact cluster + username ARN (not wildcard cluster)
#   secretsmanager   → platform/* namespace only (NOT rds!* master credential)
#   kms:Decrypt      → this environment's CMK ARN only

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.prefix}-ecs-task-policy"
  role = module.iam.ecs_task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSIAMAuth"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        # Scoped to the exact cluster resource ID and app username.
        # rds-db:connect on a wildcard cluster would allow the app to authenticate
        # against any Aurora cluster in the account — this is never acceptable.
        Resource = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${module.data.cluster_resource_id}/${var.db_username}"
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
        # platform/* covers all application secrets this service creates and reads.
        # The Aurora master credential (rds!* ARN) is intentionally excluded —
        # the app authenticates via IAM token, never the master password.
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:platform/*"
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        # Scoped to this environment's CMK only. The KMS key policy also grants
        # this access directly, but having both makes the grant visible from
        # the role's perspective (not just the key's perspective).
        Resource = module.kms.kms_key_arn
      },
    ]
  })
}

# ── Billing alarm ─────────────────────────────────────────────────────────────
#
# AWS/Billing metrics are only available in us-east-1 regardless of deployment
# region.  This project deploys to us-east-1 so no provider alias is needed.
#
# To receive alerts, subscribe your email to the SNS topic after apply:
#   aws sns subscribe \
#     --topic-arn $(terraform output -raw billing_alarm_topic_arn) \
#     --protocol email \
#     --notification-endpoint your@email.com
# Confirm the subscription via the confirmation email AWS sends.
#
# Note: AWS Billing alerts must be enabled in the account root user's
# Billing preferences before CloudWatch can publish EstimatedCharges metrics.
# Console: Billing → Billing preferences → "Receive Billing Alerts" → Save.

resource "aws_sns_topic" "billing_alarm" {
  name = "${local.prefix}-billing-alarm"
  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  alarm_name        = "${local.prefix}-estimated-charges"
  alarm_description = "Estimated AWS charges for ${local.prefix} have exceeded ${var.billing_alarm_threshold} USD. Review the Cost Explorer before applying further infrastructure."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400 # billing metrics publish once per day
  statistic           = "Maximum"
  threshold           = var.billing_alarm_threshold

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing_alarm.arn]

  tags = local.tags
}
