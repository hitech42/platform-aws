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
# RDS requires subnets in at least 2 AZs.  The network module provisions
# 2 private subnets (10.0.2.0/24, 10.0.3.0/24) with no default route — RDS
# never needs internet egress and the private route table enforces that.

resource "aws_db_subnet_group" "postgres" {
  name        = "${local.prefix}-postgres"
  subnet_ids  = var.private_subnet_ids
  description = "Private subnets for ${local.prefix} RDS PostgreSQL instance."

  tags = merge(local.tags, { Name = "${local.prefix}-postgres-subnet-group" })
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────
#
# db.t4g.micro + 20 GiB gp2 are within the AWS free-tier allowance.
# Standard RDS (not Aurora) is used here: it supports VPC placement, security
# groups, CMK encryption, and IAM database authentication together — the full
# defence-in-depth stack without requiring Aurora Express Configuration.

resource "aws_db_instance" "postgres" {
  identifier = "${local.prefix}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = "db.t4g.micro" # free-tier eligible

  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name  = var.db_name
  username = "postgres" # admin/break-glass user only — app uses IAM auth as var.db_username

  # AWS manages the master password and stores it in Secrets Manager automatically,
  # encrypted with our CMK.  No password is ever handled in Terraform state or
  # CI environment variables.  See DECISIONS.md (ADR-009).
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [var.db_sg_id]

  iam_database_authentication_enabled = true

  # No public internet access — inbound port 5432 is restricted to ecs_service_sg
  # by the DB security group; the private subnet route table has no default route.
  publicly_accessible = false

  # Single AZ is sufficient for dev cost control.
  # Set multi_az=true in staging/prod for failover.
  multi_az = false

  # Dev: clean destroy without a final snapshot.  In production, flip both:
  #   deletion_protection = true   — requires a second apply to remove before destroy
  #   skip_final_snapshot = false  — ensures a last backup before any destroy
  deletion_protection = false
  skip_final_snapshot = true

  tags = merge(local.tags, { Name = "${local.prefix}-postgres" })
}
