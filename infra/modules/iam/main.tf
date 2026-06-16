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

  # Full OIDC subject claim patterns this role's trust policy accepts.
  # Ref-based: "repo:hitech42/platform-aws:ref:refs/heads/develop" — used by
  #   jobs that do NOT declare a GitHub environment.
  # Environment-based: "repo:hitech42/platform-aws:environment:dev" — used by
  #   jobs that DO declare `environment: dev` (the sub claim's ref component
  #   is replaced entirely, not appended, when a job uses an environment).
  oidc_subjects = concat(
    [for ref in var.allowed_refs : "repo:${var.github_org}/${var.github_repo}:ref:${ref}"],
    [for env in var.allowed_environments : "repo:${var.github_org}/${var.github_repo}:environment:${env}"],
  )

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
        ]
        Resource = "arn:aws:iam::*:role/${var.project_name}-*"
      },
      # PassRole is in a separate statement so it can carry a PassedToService
      # condition — the role can only be passed to ECS tasks, not arbitrary
      # services.  Scoped to exactly the task execution and task role name
      # patterns; does not cover the deploy role itself.
      {
        Sid    = "ECSPassRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::*:role/${var.project_name}-*-ecs-task-execution",
          "arn:aws:iam::*:role/${var.project_name}-*-ecs-task",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },

      # ── 5. RDS — instance and subnet group ───────────────────────────────────
      #
      # Mutating actions are scoped to project-prefixed resource ARNs.
      # Describe/List actions use Resource="*" — AWS does not support resource-
      # level ARNs for most Describe operations (they are account-wide list calls).
      {
        Sid    = "RDSManage"
        Effect = "Allow"
        Action = [
          # Instance lifecycle
          "rds:CreateDBInstance",
          "rds:DeleteDBInstance",
          "rds:ModifyDBInstance",
          "rds:RebootDBInstance",
          "rds:RestoreDBInstanceFromDBSnapshot",
          # Subnet group
          "rds:CreateDBSubnetGroup",
          "rds:DeleteDBSubnetGroup",
          "rds:ModifyDBSubnetGroup",
          # Snapshots
          "rds:CreateDBSnapshot",
          "rds:DeleteDBSnapshot",
          "rds:CopyDBSnapshot",
          # Tags
          "rds:AddTagsToResource",
          "rds:RemoveTagsFromResource",
          "rds:ListTagsForResource",
        ]
        Resource = [
          "arn:aws:rds:*:*:db:${var.project_name}-*",
          "arn:aws:rds:*:*:subgrp:${var.project_name}-*",
          "arn:aws:rds:*:*:snapshot:${var.project_name}-*",
        ]
      },
      {
        Sid    = "RDSDescribeGlobal"
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:DescribeDBSubnetGroups",
          "rds:DescribeDBSnapshots",
          "rds:DescribeDBEngineVersions",
          "rds:DescribeOrderableDBInstanceOptions",
          "rds:DescribeDBParameterGroups",
          "rds:DescribeEvents",
        ]
        Resource = "*"
      },

      # ── 6. KMS — customer-managed key lifecycle ────────────────────────────
      #
      # Resource="*" is required: kms:CreateKey has no ARN to scope to before
      # the key exists, and kms:ListKeys/ListAliases are account-wide.
      # TODO (prod hardening): split into CreateKey (Resource="*") and key-lifecycle
      # actions (Resource=specific key ARN with aws:ResourceTag condition).
      {
        Sid    = "KMSManage"
        Effect = "Allow"
        Action = [
          "kms:CreateKey",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListKeys",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant",
          "kms:CreateAlias",
          "kms:DeleteAlias",
          "kms:UpdateAlias",
        ]
        Resource = "*"
      },

      # ── 7. Secrets Manager — app secrets + RDS master credential ─────────
      #
      # App secrets follow platform/{service}/{env}/{name} naming (ARN suffix
      # secret:platform/*).  The RDS-managed master credential is named
      # rds!* by AWS; Terraform reads its ARN from the instance attributes.
      # The ECS task role does NOT have access to rds!* secrets — the app
      # authenticates via IAM token, never the master credential.
      {
        Sid    = "SecretsManagerAppSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:TagResource",
          "secretsmanager:UntagResource",
          "secretsmanager:ListSecretVersionIds",
          "secretsmanager:RestoreSecret",
        ]
        Resource = [
          "arn:aws:secretsmanager:*:*:secret:platform/*", # app secrets
          "arn:aws:secretsmanager:*:*:secret:rds!*",      # RDS-managed master credential
        ]
      },
      {
        Sid      = "SecretsManagerList"
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets"]
        Resource = "*" # ListSecrets does not support resource-level permissions
      },

      # ── 8. ECR — repository management + image push ───────────────────────
      #
      # ecr:GetAuthorizationToken has no resource ARN concept — it returns a
      # registry-level token valid for any repo in the account.  AWS requires
      # Resource="*" for this action; it carries no mutating capability.
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRManage"
        Effect = "Allow"
        Action = [
          # Terraform lifecycle
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:DescribeRepositories",
          "ecr:TagResource",
          "ecr:UntagResource",
          "ecr:ListTagsForResource",
          "ecr:SetRepositoryPolicy",
          "ecr:GetRepositoryPolicy",
          "ecr:DeleteRepositoryPolicy",
          "ecr:GetLifecyclePolicy",
          "ecr:PutLifecyclePolicy",
          "ecr:DeleteLifecyclePolicy",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutEncryptionConfiguration",
          # CI/CD image push
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          # CI/CD image pull (also used by task execution role — separate policy)
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:BatchDeleteImage",
        ]
        # Scoped to the single project repository; name matches var.project_name.
        Resource = "arn:aws:ecr:*:*:repository/${var.project_name}"
      },

      # ── 9. ECS — cluster, service, task definition lifecycle ─────────────
      #
      # Task definition ARNs include a revision number unknown until registration,
      # so RegisterTaskDefinition / DescribeTaskDefinition must use Resource="*".
      # Cluster and service ARNs use the project-name prefix for scoping.
      {
        Sid    = "ECSTaskDefinitions"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DeregisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTaskDefinitions",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECSClusterManage"
        Effect = "Allow"
        Action = [
          "ecs:CreateCluster",
          "ecs:DeleteCluster",
          "ecs:UpdateClusterSettings",
          "ecs:DescribeClusters",
          "ecs:ListClusters",
          "ecs:TagResource",
          "ecs:UntagResource",
          "ecs:ListTagsForResource",
        ]
        Resource = "arn:aws:ecs:*:*:cluster/${var.project_name}-*"
      },
      {
        Sid    = "ECSServiceManage"
        Effect = "Allow"
        Action = [
          "ecs:CreateService",
          "ecs:DeleteService",
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:ListServices",
        ]
        # Service ARN format: arn:aws:ecs:REGION:ACCOUNT:service/CLUSTER/SERVICE
        Resource = "arn:aws:ecs:*:*:service/${var.project_name}-*/${var.project_name}-*"
      },
      # The deploy pipeline runs `alembic upgrade head` as a one-off Fargate
      # task before updating the service (app-deploy.yml). RunTask is scoped
      # to this project's task definition family and, via the ecs:cluster
      # condition, to this project's cluster — it cannot launch arbitrary task
      # definitions or run tasks in unrelated clusters.
      {
        Sid    = "ECSRunTask"
        Effect = "Allow"
        Action = ["ecs:RunTask"]
        Resource = [
          "arn:aws:ecs:*:*:task-definition/${var.project_name}-*",
          "arn:aws:ecs:*:*:task-definition/${var.project_name}-*:*",
        ]
        Condition = {
          ArnLike = {
            "ecs:cluster" = "arn:aws:ecs:*:*:cluster/${var.project_name}-*"
          }
        }
      },
      # Task ARNs are only known after RunTask returns, so DescribeTasks/StopTask
      # are scoped to the cluster-name component instead of a specific task ID.
      {
        Sid    = "ECSTaskRuntime"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTasks",
          "ecs:StopTask",
        ]
        Resource = "arn:aws:ecs:*:*:task/${var.project_name}-*/*"
      },

      # ── 10. ALB — load balancer, target group, listener ────────────────────
      #
      # Describe* actions require Resource="*" (AWS limitation — no ARN concept
      # for list/describe calls on ELB resources).  Mutating actions are scoped
      # to project-prefixed resource ARNs.
      {
        Sid      = "ALBDescribeGlobal"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:Describe*"]
        Resource = "*"
      },
      {
        Sid    = "ALBManage"
        Effect = "Allow"
        Action = [
          # Load balancer lifecycle
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          # Target group lifecycle
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          # Listener lifecycle
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:ModifyListener",
          # Tags
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/${var.project_name}-*/*",
          "arn:aws:elasticloadbalancing:*:*:targetgroup/${var.project_name}-*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/${var.project_name}-*/*/*",
        ]
      },

      # ── 11. CloudWatch Logs — ECS log group management ─────────────────────
      #
      # logs:DescribeLogGroups requires Resource="*" (AWS limitation).
      # Mutating actions are scoped to the /ecs/{project_name}-* log group prefix.
      {
        Sid      = "CWLogsDescribeGlobal"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "CWLogsManage"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:PutRetentionPolicy",
          "logs:TagLogGroup",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:ListTagsLogGroup",
          "logs:ListTagsForResource",
          "logs:AssociateKmsKey",
          "logs:DisassociateKmsKey",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/${var.project_name}-*"
      },

      # TODO (E4): add for CloudWatch metrics + alarms + billing notifications:
      #   cloudwatch:PutMetricAlarm, cloudwatch:DeleteAlarms,
      #   cloudwatch:DescribeAlarms, cloudwatch:PutDashboard,
      #   sns:CreateTopic, sns:DeleteTopic, sns:SetTopicAttributes,
      #   sns:GetTopicAttributes, sns:TagResource,
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
  description = "ECS agent role: pull images from ECR, write logs to CloudWatch (permissions added in E3)."

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

  # Inline policies for this role are attached in infra/envs/dev/main.tf as
  # aws_iam_role_policy.ecs_task_execution — they need the ECR repo ARN and
  # CloudWatch log group ARN from the ecs-service module, which would create a
  # dependency cycle if placed here.  The same pattern is used for ecs_task.
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
  description = "Application runtime role: Secrets Manager + RDS IAM auth."

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

  # The inline policy for this role (rds-db:connect, secretsmanager:*, kms:Decrypt)
  # is attached as aws_iam_role_policy.ecs_task in infra/envs/dev/main.tf rather
  # than here.  This avoids a module dependency cycle: the rds-db:connect ARN
  # requires the RDS db_resource_id (from the data module), which depends
  # on the KMS key (from the kms module), which in turn references this role's ARN.
  # Placing the policy in the root module (envs/dev) breaks the cycle cleanly.
}
