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

  # Full OIDC subject claim pattern for this environment's allowed refs.
  # e.g. "repo:hitech42/platform-aws:ref:refs/heads/develop"
  oidc_subjects = [
    for ref in var.allowed_refs :
    "repo:${var.github_org}/${var.github_repo}:ref:${ref}"
  ]

  oidc_provider_arn = var.create_oidc_provider ? (
    aws_iam_openid_connect_provider.github[0].arn
  ) : data.aws_iam_openid_connect_provider.github[0].arn
}

# ── GitHub OIDC provider ──────────────────────────────────────────────────────
#
# Account-wide resource — only one can exist per AWS account regardless of
# environment.  Toggle create_oidc_provider=false if it already exists.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.oidc_thumbprints

  tags = merge(local.tags, { Name = "github-actions-oidc" })
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

# ── GitHub Actions deploy role ────────────────────────────────────────────────
#
# One role per environment — trust policy restricts assumption to a specific
# repo + branch (var.allowed_refs).  See variables.tf for the design rationale.

resource "aws_iam_role" "github_deploy" {
  name        = "${local.prefix}-github-deploy"
  description = "Assumed by GitHub Actions (${var.github_org}/${var.github_repo}) to deploy ${var.environment}."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GitHubOIDC"
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # StringLike (not StringEquals) so callers can pass glob patterns in
        # var.allowed_refs if needed (e.g. "refs/heads/feature/*" for PR plans).
        # For exact branch matches there is no functional difference.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.oidc_subjects
        }
      }
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-github-deploy" })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "${local.prefix}-github-deploy-policy"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # ── 1. Terraform state backend ─────────────────────────────────────────
      {
        Sid    = "StateBackendBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion",
        ]
        Resource = "arn:aws:s3:::${var.state_bucket_name}/*"
      },
      {
        Sid      = "StateBackendBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = "arn:aws:s3:::${var.state_bucket_name}"
      },
      {
        Sid    = "StateBackendLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:aws:dynamodb:*:*:table/${var.state_lock_table_name}"
      },

      # ── 2. EC2 read-only (Describe / List) ────────────────────────────────
      #
      # AWS requires Resource="*" for Describe* actions — these are account-level
      # read operations with no resource ARN concept (the API returns results
      # filtered by the account, not by a specific ARN).  Describe/List actions
      # carry no mutating capability; granting them on "*" is acceptable under
      # the "no wildcard actions" guideline because the guideline targets
      # write/delete actions, not read-only enumeration.
      {
        Sid    = "EC2ReadOnly"
        Effect = "Allow"
        Action = ["ec2:Describe*"]
        # Resource must be "*" — AWS does not support resource-level permissions
        # for Describe operations (they are list/read operations that scan the
        # account, not operations on a specific resource ARN).
        Resource = "*"
      },

      # ── 3. EC2 mutating (VPC, subnets, SGs, route tables, IGW) ───────────
      #
      # Resource is "*" here too because:
      #  - EC2 VPC resources don't have stable ARNs until after creation, so
      #    you can't pre-scope a CreateVpc permission to a specific ARN.
      #  - For tighter scoping in staging/prod, use aws:RequestTag conditions
      #    (e.g. require Project=cvs-platform tag on all Create* calls) and
      #    aws:ResourceTag conditions (scope Delete*/Modify* to tagged resources).
      #    TODO (E4 / prod hardening): add tag-based conditions here.
      {
        Sid    = "EC2NetworkMutate"
        Effect = "Allow"
        Action = [
          # VPC
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:ModifyVpcAttribute",
          # Subnets
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:ModifySubnetAttribute",
          # Internet Gateway
          "ec2:CreateInternetGateway",
          "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:DetachInternetGateway",
          # Route tables
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable",
          "ec2:AssociateRouteTable",
          "ec2:DisassociateRouteTable",
          "ec2:CreateRoute",
          "ec2:DeleteRoute",
          # Security groups
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          # Tags (required on all Create* calls that accept tags)
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "*"
      },

      # ── 4. IAM — OIDC provider and project roles/policies ─────────────────
      #
      # Scoped to project-prefixed roles and policies where possible.
      # The OIDC provider ARN is account-global so must use a broader pattern.
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:RemoveClientIDFromOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
      },
      {
        Sid    = "IAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:ListRoles",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          # PassRole is needed in E2/E3 when Terraform registers the ECS task
          # definition and passes the task execution / task roles to ECS.
          # Granted now so the role's scope is consistent even before ECS exists.
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::*:role/${var.project_name}-*"
      },

      # TODO (E2): add the following to this policy when wiring up ECS + ECR:
      #   ecs:*, ecr:GetAuthorizationToken, ecr:BatchCheckLayerAvailability,
      #   ecr:GetDownloadUrlForLayer, ecr:BatchGetImage, ecr:DescribeRepositories,
      #   ecr:CreateRepository, ecr:DeleteRepository, ecr:TagResource,
      #   logs:CreateLogGroup, logs:DeleteLogGroup, logs:DescribeLogGroups,
      #   logs:PutRetentionPolicy, logs:TagLogGroup,
      #   secretsmanager:CreateSecret, secretsmanager:DeleteSecret,
      #   secretsmanager:DescribeSecret, secretsmanager:GetSecretValue,
      #   secretsmanager:PutSecretValue, secretsmanager:TagResource,
      #   elasticloadbalancing:* (ALB + target groups + listeners)

      # TODO (E3): add for Aurora + KMS:
      #   rds:*, kms:CreateKey, kms:DescribeKey, kms:CreateAlias,
      #   kms:DeleteAlias, kms:EnableKeyRotation, kms:TagResource,
      #   kms:CreateGrant (for RDS to use the key)

      # TODO (E4): add for CloudWatch metrics + alarms:
      #   cloudwatch:PutMetricAlarm, cloudwatch:DeleteAlarms,
      #   cloudwatch:DescribeAlarms, cloudwatch:PutDashboard,
      #   logs:PutMetricFilter, logs:DeleteMetricFilter

    ]
  })
}

# ── ECS task execution role ───────────────────────────────────────────────────
#
# Used by the ECS agent (not the app) to:
#   - Pull the container image from ECR                    (added in E2)
#   - Write container logs to CloudWatch Logs              (added in E2)
#   - Fetch secret values for environment variable injection (added in E2)
#
# The AWS-managed AmazonECSTaskExecutionRolePolicy is NOT attached here because
# it grants ECR and CloudWatch access without scoping to specific resources.
# E2 will attach narrowly-scoped inline policies instead.

resource "aws_iam_role" "ecs_task_execution" {
  name        = "${local.prefix}-ecs-task-execution"
  description = "ECS agent role: pull images from ECR, write logs to CloudWatch (permissions added in E2)."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ECSTasksAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-ecs-task-execution" })

  # TODO (E2): attach inline policies for:
  #   - ecr:GetAuthorizationToken on * (required — no resource ARN for auth token)
  #   - ecr:BatchCheckLayerAvailability, ecr:GetDownloadUrlForLayer,
  #     ecr:BatchGetImage on the specific ECR repository ARN
  #   - logs:CreateLogStream, logs:PutLogEvents on the specific log group ARN
  #   - secretsmanager:GetSecretValue on specific secret ARNs (env var injection)
}

# ── ECS task role ─────────────────────────────────────────────────────────────
#
# Used BY the application container (not the ECS agent) for AWS API calls the
# app makes at runtime:
#   - Secrets Manager: read the provisioned secret values   (added in E2)
#   - RDS IAM auth token generation                         (added in E3)
#
# Keep this role separate from the execution role: execution role is the ECS
# infrastructure concern; task role is the application concern.

resource "aws_iam_role" "ecs_task" {
  name        = "${local.prefix}-ecs-task"
  description = "Application runtime role: Secrets Manager + RDS IAM auth (permissions added in E2/E3)."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ECSTasksAssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${local.prefix}-ecs-task" })

  # TODO (E2): attach inline policy for:
  #   secretsmanager:GetSecretValue, secretsmanager:DescribeSecret
  #   on arn:aws:secretsmanager:*:*:secret:platform/<service>/<env>/*
  #
  # TODO (E3): attach inline policy for:
  #   rds-db:connect on the Aurora cluster resource ARN
  #   (enables RDS IAM authentication — no password needed in the app)
}
