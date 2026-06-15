# Run from infra/modules/iam/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider so no AWS credentials are required.
#
# Why command=apply (not plan) for most runs:
#   assume_role_policy is built with jsonencode() that embeds
#   aws_iam_openid_connect_provider.github[0].arn — a computed value.
#   With command=plan that value is (known after apply), making the entire
#   JSON string unknown and untestable.  command=apply with mock_provider
#   resolves all computed attributes in memory without hitting real AWS.
#   Runs within a file share state, so the first apply creates all resources
#   and subsequent runs can read them.

mock_provider "aws" {}

variables {
  project_name         = "test"
  environment          = "dev"
  github_org           = "myorg"
  github_repo          = "myrepo"
  state_bucket_name    = "test-tfstate-123456789"
  create_oidc_provider = true
  # allowed_refs uses module default: ["refs/heads/develop"]
}

# ── GitHub Actions role: OIDC trust policy ────────────────────────────────────

run "github_role_trust_policy" {
  command = apply

  # The sub condition must be an exact repo:ORG/REPO:ref:BRANCH string — never
  # a wildcard like "repo:*" that would allow any repository to assume this role.
  assert {
    condition = contains(
      jsondecode(aws_iam_role.github_deploy.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"],
      "repo:myorg/myrepo:ref:refs/heads/develop"
    )
    error_message = "OIDC trust sub condition must exactly match 'repo:ORG/REPO:ref:refs/heads/BRANCH'. A wildcard like 'repo:*' would allow any GitHub repository to assume this role."
  }

  # The aud condition must be sts.amazonaws.com — required by AWS for OIDC
  # token exchange via GitHub Actions.
  assert {
    condition     = jsondecode(aws_iam_role.github_deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "OIDC trust aud condition must be 'sts.amazonaws.com'."
  }

  # Role name must encode both project and environment so roles from different
  # environments cannot collide in the same AWS account.
  assert {
    condition     = aws_iam_role.github_deploy.name == "${var.project_name}-${var.environment}-github-deploy"
    error_message = "Deploy role name must be '{project_name}-{environment}-github-deploy'."
  }
}

# ── GitHub Actions role: deploy policy — no catch-all wildcard actions ────────

run "github_deploy_policy_no_wildcard_actions" {
  command = apply

  # No statement may use Action="*" (grant all actions in every AWS service).
  # Service-scoped wildcards like "ec2:Describe*" are present in the policy for
  # read-only list operations and are acceptable; the guard here is the
  # catch-all "*" that would bypass least-privilege entirely.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      contains(tolist(s.Action), "*")
    ])
    error_message = "GitHub Actions deploy policy must not contain Action=[\"*\"]. Use specific action names or service-scoped wildcards (e.g. \"ec2:Describe*\") instead."
  }

  # Belt-and-suspenders: no statement that has BOTH Action=* AND Resource=*.
  # This is the most dangerous combination (unrestricted access to all resources).
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      (s.Effect == "Allow" && contains(tolist(s.Action), "*") && contains(tolist(s.Resource), "*"))
    ])
    error_message = "Deploy policy must not have any Allow statement with both Action=[*] and Resource=[*]."
  }
}

# ── ECS task roles: no inline policies in the iam module ─────────────────────
#
# The ECS task role's runtime policy (rds-db:connect, secretsmanager, kms:Decrypt)
# lives in infra/envs/dev/main.tf as aws_iam_role_policy.ecs_task, not here.
# This is deliberate: the policy needs the Aurora cluster_resource_id (from the
# data module) which creates a dependency cycle if placed inside this module.
# The execution role's policies are added in E3 (ECR + CloudWatch Log group ARNs).

run "ecs_roles_have_no_inline_policies" {
  command = apply

  assert {
    condition     = length(aws_iam_role.ecs_task_execution.inline_policy) == 0
    error_message = "ECS task execution role must have no inline policies in the iam module. Permissions are added in E3 once ECR repo and log group ARNs are known."
  }

  assert {
    condition     = length(aws_iam_role.ecs_task.inline_policy) == 0
    error_message = "ECS task role inline policy lives in envs/dev (not here) to avoid a module dependency cycle. See aws_iam_role_policy.ecs_task in infra/envs/dev/main.tf."
  }
}

# ── ECS task roles: trust principal is ecs-tasks only ────────────────────────
#
# Trust policy contains only static strings (no computed values), so command=plan
# would also work here, but we use apply for consistency within the file.

run "ecs_roles_trust_ecs_tasks_only" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role.ecs_task_execution.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    error_message = "ECS task execution role trust policy must allow only ecs-tasks.amazonaws.com."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ecs_task.assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com"
    error_message = "ECS task role trust policy must allow only ecs-tasks.amazonaws.com."
  }
}

# ── GitHub deploy policy: RDS scoped to project-prefixed ARNs ────────────────
#
# RDS mutating actions must be scoped to project-prefixed resource ARNs —
# not account-wide "*".  Describe actions may use "*" (AWS limitation).

run "github_deploy_rds_scoped" {
  command = apply

  # The RDSManage statement must exist and its resources must all start with
  # arn:aws:rds — never a bare "*".
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      s.Sid == "RDSManage" &&
      alltrue([for r in tolist(s.Resource) : startswith(r, "arn:aws:rds:")])
    ])
    error_message = "RDSManage statement must exist and scope all resources to arn:aws:rds:* ARNs, not '*'."
  }

  # RDS mutating actions must be scoped to project-prefixed cluster/db/subgrp ARNs.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      s.Sid == "RDSManage" &&
      anytrue([for r in tolist(s.Resource) : can(regex("arn:aws:rds:\\*:\\*:cluster:${var.project_name}-\\*", r))])
    ])
    error_message = "RDSManage resources must include arn:aws:rds:*:*:cluster:{project_name}-* to scope cluster operations to this project."
  }
}

# ── GitHub deploy policy: Secrets Manager scoped to /platform/* and rds!* ────
#
# The deploy role must not have access to arbitrary Secrets Manager secrets —
# only the application namespace (platform/*) and Aurora master credential (rds!*).

run "github_deploy_secrets_scoped" {
  command = apply

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      s.Sid == "SecretsManagerAppSecrets" &&
      anytrue([for r in tolist(s.Resource) : can(regex("arn:aws:secretsmanager:\\*:\\*:secret:platform/\\*", r))])
    ])
    error_message = "SecretsManagerAppSecrets must scope resources to arn:aws:secretsmanager:*:*:secret:platform/* for app secrets."
  }

  # Must NOT grant GetSecretValue on wildcard "*" — that would expose all secrets.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.github_deploy.policy).Statement :
      contains(tolist(s.Action), "secretsmanager:GetSecretValue") &&
      contains(tolist(s.Resource), "*")
    ])
    error_message = "secretsmanager:GetSecretValue must never be granted on Resource='*'. Scope to platform/* and rds!* ARNs only."
  }
}
