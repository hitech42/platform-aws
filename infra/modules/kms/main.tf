terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── Customer-managed KMS key ───────────────────────────────────────────────────
#
# One key per environment used for:
#   - RDS instance storage encryption
#   - RDS-managed master credential in Secrets Manager (master_user_secret_kms_key_id)
#   - Application secrets written by the platform API (/platform/* namespace)
#   - CloudWatch log group encryption (E3)
#
# A single key keeps cross-service access grants simple; rotate to per-service
# keys if your threat model requires blast-radius reduction.

resource "aws_kms_key" "platform" {
  description             = "Platform CMK for ${local.prefix}: RDS, Secrets Manager, CloudWatch."
  deletion_window_in_days = 7 # Dev: minimum window for clean teardowns. Use 30 in staging/prod.
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Root account has full administrative control.
      # Required — without this the key becomes unmanageable if all IAM-granted
      # access is revoked.  Does NOT grant root access by default; this statement
      # enables it explicitly so IAM policies can further restrict operations.
      {
        Sid    = "RootFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # RDS service principal uses this key for RDS storage encryption and
      # for encrypting the RDS-managed master credential in Secrets Manager.
      # CreateGrant lets RDS establish a key grant so it can call kms:Decrypt
      # on behalf of your account without requiring a user-present session.
      {
        Sid    = "RDSEncryption"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      # ECS task role (the app container) needs Decrypt to read CMK-encrypted
      # Secrets Manager secrets at runtime.  GenerateDataKey is needed when the
      # app writes a new secret value (Secrets Manager re-encrypts on PutSecretValue).
      # The task role does NOT get Encrypt, CreateGrant, or any key admin action.
      {
        Sid    = "ECSTaskDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = var.ecs_task_role_arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-platform-key" })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${local.prefix}"
  target_key_id = aws_kms_key.platform.key_id
}
