# Run from infra/envs/dev/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider to avoid real AWS credentials.
# command=apply is required throughout because several resources embed computed
# values (OIDC provider ARN) that are unknown at plan time and would make
# assertion expressions unevaluable.
#
# Override strategy for apply runs
# ─────────────────────────────────
# These tests verify the *wiring* of envs/dev (do modules connect correctly?),
# not the internals of each module.  Module internals are tested in their own
# tests/.tftest.hcl files.
#
# module.kms     → override_module: mock provider returns non-ARN strings for
#                  kms_key_arn (e.g. "9q3cpkep"), which fails kms_key_id
#                  validation on aws_rds_cluster.  A valid fake ARN unblocks
#                  module.data and aws_iam_role_policy.ecs_task.
#
# module.data    → override_module: the mock provider returns an empty list for
#                  master_user_secret (AWS only populates it post-provisioning),
#                  causing master_user_secret[0] to panic.  Known fake values
#                  also give deterministic cluster_resource_id for assertions.
#
# aws_sns_topic.billing_alarm
#                → override_resource: mock-generated arn ("wr16sars") fails
#                  alarm_actions ARN validation on aws_cloudwatch_metric_alarm.
#
# data sources   → override_data: aws_caller_identity and aws_region return
#                  null attributes from the mock provider, which would produce
#                  invalid ARN strings in resource policies.

mock_provider "aws" {}

variables {
  project_name      = "test"
  environment       = "dev"
  github_org        = "myorg"
  github_repo       = "myrepo"
  state_bucket_name = "test-tfstate-123456789"
  db_username       = "platform_app"
  db_name           = "platform"
}

# ── Re-usable locals for mock ARNs (Terraform test files share a module scope,
#    so locals defined in one run can be referenced by subsequent runs.)
# NOTE: .tftest.hcl does not support top-level locals — values are repeated
# across runs intentionally to keep each run self-contained and readable.

# ── environment variable validation ──────────────────────────────────────────

run "invalid_environment_rejected" {
  command = plan

  variables {
    environment = "production" # not in ["dev", "staging", "prod"]
  }

  # Variable validation fires before any module is instantiated — plan fails fast.
  expect_failures = [var.environment]
}

# ── modules instantiate and wire cleanly ─────────────────────────────────────

run "valid_environment_accepted" {
  command = apply

  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  override_module {
    target = module.kms
    outputs = {
      kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
      kms_key_id    = "00000000-0000-0000-0000-000000000001"
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-dev"
    }
  }

  override_module {
    target = module.data
    outputs = {
      cluster_endpoint        = "test-dev-aurora.cluster-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_reader_endpoint = "test-dev-aurora.cluster-ro-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_resource_id     = "cluster-AAAAAAAAAAAAAAAAAAAAA"
      cluster_arn             = "arn:aws:rds:us-east-1:123456789012:cluster:test-dev-aurora"
      port                    = 5432
      database_name           = "platform"
      db_username             = "platform_app"
      master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!cluster-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_resource {
    target = aws_sns_topic.billing_alarm
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:test-dev-billing-alarm"
    }
  }

  assert {
    condition     = module.iam.github_actions_role_arn != ""
    error_message = "GitHub Actions role ARN must be non-empty when environment is valid."
  }
}

# ── ECS task policy: rds-db:connect must be scoped to one cluster + user ──────
#
# rds-db:connect on Resource="*" would allow the app to authenticate as any
# username against any Aurora cluster in the account.  The ARN must be scoped
# to this environment's cluster resource ID and the specific app DB username.

run "ecs_task_policy_rds_scoped" {
  command = apply

  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  override_module {
    target = module.kms
    outputs = {
      kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
      kms_key_id    = "00000000-0000-0000-0000-000000000001"
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-dev"
    }
  }

  override_module {
    target = module.data
    outputs = {
      cluster_endpoint        = "test-dev-aurora.cluster-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_reader_endpoint = "test-dev-aurora.cluster-ro-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_resource_id     = "cluster-AAAAAAAAAAAAAAAAAAAAA"
      cluster_arn             = "arn:aws:rds:us-east-1:123456789012:cluster:test-dev-aurora"
      port                    = 5432
      database_name           = "platform"
      db_username             = "platform_app"
      master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!cluster-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_resource {
    target = aws_sns_topic.billing_alarm
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:test-dev-billing-alarm"
    }
  }

  # rds-db:connect must never be on wildcard Resource.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "rds-db:connect") && tostring(s.Resource) == "*"
    ])
    error_message = "rds-db:connect must never be granted on Resource='*'. Scope to the exact Aurora cluster resource ID ARN."
  }

  # The resource ARN must end with the app DB username so the grant is user-specific.
  # This prevents the app from connecting as any other DB user (including postgres).
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "rds-db:connect") &&
      endswith(tostring(s.Resource), "/${var.db_username}")
    ])
    error_message = "rds-db:connect Resource must end with '/${var.db_username}' to scope the grant to the app DB user only, not the postgres master user."
  }

  # The resource ARN must embed the cluster resource ID — not a wildcard cluster.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "rds-db:connect") &&
      can(regex("dbuser:cluster-", tostring(s.Resource)))
    ])
    error_message = "rds-db:connect Resource must contain 'dbuser:cluster-<resource_id>' to identify the specific Aurora cluster."
  }
}

# ── ECS task policy: Secrets Manager must not expose the Aurora master cred ───
#
# The Aurora master credential lives in the rds!* Secrets Manager namespace
# (AWS-managed, outside the platform/* app namespace).  The app authenticates
# via IAM token and must NEVER receive GetSecretValue on rds!* — that would
# give it the admin password with no per-access audit trail.

run "ecs_task_policy_secrets_scoped" {
  command = apply

  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  override_module {
    target = module.kms
    outputs = {
      kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
      kms_key_id    = "00000000-0000-0000-0000-000000000001"
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-dev"
    }
  }

  override_module {
    target = module.data
    outputs = {
      cluster_endpoint        = "test-dev-aurora.cluster-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_reader_endpoint = "test-dev-aurora.cluster-ro-xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      cluster_resource_id     = "cluster-AAAAAAAAAAAAAAAAAAAAA"
      cluster_arn             = "arn:aws:rds:us-east-1:123456789012:cluster:test-dev-aurora"
      port                    = 5432
      database_name           = "platform"
      db_username             = "platform_app"
      master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!cluster-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_resource {
    target = aws_sns_topic.billing_alarm
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:test-dev-billing-alarm"
    }
  }

  # GetSecretValue on Resource="*" would expose every secret in the account.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "secretsmanager:GetSecretValue") &&
      tostring(s.Resource) == "*"
    ])
    error_message = "secretsmanager:GetSecretValue must never be granted on Resource='*'."
  }

  # GetSecretValue must be scoped to the platform/* app secret namespace.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "secretsmanager:GetSecretValue") &&
      can(regex("secret:platform/", tostring(s.Resource)))
    ])
    error_message = "secretsmanager:GetSecretValue must be scoped to the platform/* namespace."
  }

  # GetSecretValue must NOT cover the Aurora master credential (rds!* namespace).
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "secretsmanager:GetSecretValue") &&
      can(regex("secret:rds!", tostring(s.Resource)))
    ])
    error_message = "secretsmanager:GetSecretValue must NOT be granted on rds!* secrets. The app never reads the Aurora master credential."
  }
}
