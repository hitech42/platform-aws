terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── DB Subnet Group ───────────────────────────────────────────────────────────
#
# Aurora requires subnets in at least 2 AZs.  The network module provisions
# 2 private subnets (10.0.2.0/24, 10.0.3.0/24) with no default route — Aurora
# never needs internet egress and the private route table enforces that.

resource "aws_db_subnet_group" "aurora" {
  name        = "${local.prefix}-aurora"
  subnet_ids  = var.private_subnet_ids
  description = "Private subnets for ${local.prefix} Aurora cluster."

  tags = merge(local.tags, { Name = "${local.prefix}-aurora-subnet-group" })
}

# ── Aurora PostgreSQL Serverless v2 Cluster ───────────────────────────────────
#
# Serverless v2 uses engine_mode="provisioned" — NOT "serverless".
# "serverless" is the legacy Aurora Serverless v1 API.  The v2 behaviour
# is controlled entirely by the serverlessv2_scaling_configuration block.

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${local.prefix}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"

  # Verify available engine versions:
  #   aws rds describe-db-engine-versions \
  #     --engine aurora-postgresql \
  #     --filters Name=status,Values=available \
  #     --query 'DBEngineVersions[?SupportedEngineModes[?contains(@,`provisioned`)]].EngineVersion'
  engine_version = var.engine_version

  database_name   = var.db_name
  master_username = "postgres" # admin/break-glass user only — app uses IAM auth as var.db_username

  # AWS manages the master password and stores it in Secrets Manager automatically,
  # encrypted with our CMK.  No password is ever handled in Terraform state or
  # CI environment variables.  See DECISIONS.md (ADR-009).
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  serverlessv2_scaling_configuration {
    min_capacity = var.min_capacity
    # max_capacity = 1 ACU ≈ 2 GiB RAM keeps dev costs near zero when idle.
    # Aurora Serverless v2 scales to min_capacity between requests, so expected
    # baseline cost is ~$0.06/ACU-hr × 0.5 ACU ≈ $0.03/hr = ~$22/mo at idle.
    # Raise max_capacity to 4–16 for load testing or staging.
    max_capacity = var.max_capacity
  }

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [var.db_sg_id]

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  iam_database_authentication_enabled = true

  # Dev: clean destroy without a final snapshot.  In production, flip both:
  #   deletion_protection = true   — requires a second apply to remove before destroy
  #   skip_final_snapshot = false  — ensures a last backup before any destroy
  deletion_protection = false
  skip_final_snapshot = true

  # The RDS Data API (HTTP endpoint) lets you run SQL via aws rds-data without
  # a direct TCP connection into the VPC.  Enabled so the IAM DB user bootstrap
  # script (infra/scripts/setup-db-user.sh) can run from any machine with AWS
  # credentials — no bastion or VPN required.  Still requires IAM authentication
  # to use, so enabling it does not open a new attack surface.
  enable_http_endpoint = var.enable_http_endpoint

  tags = merge(local.tags, { Name = "${local.prefix}-aurora" })
}

# ── Aurora Instance (Serverless v2) ──────────────────────────────────────────
#
# One writer instance is sufficient for dev.  For staging/prod, add a second
# aws_rds_cluster_instance with a different identifier to enable multi-AZ
# failover and validate reader endpoint behaviour before production deploys.

resource "aws_rds_cluster_instance" "aurora" {
  identifier         = "${local.prefix}-aurora-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  tags = merge(local.tags, { Name = "${local.prefix}-aurora-1" })
}
