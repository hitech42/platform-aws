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
# module.kms        → override_module: mock provider returns non-ARN strings for
#                     kms_key_arn (e.g. "9q3cpkep"), which fails kms_key_id
#                     validation on aws_db_instance.  A valid fake ARN unblocks
#                     module.data and aws_iam_role_policy.ecs_task.
#
# module.data       → override_module: the mock provider returns an empty list for
#                     master_user_secret (AWS only populates it post-provisioning),
#                     causing master_user_secret[0] to panic.  Known fake values
#                     also give deterministic db_resource_id for assertions.
#
# module.ecs_service → override_module: the mock provider returns non-ARN strings
#                     for ecr_repository_arn and log_group_arn, which are embedded
#                     in aws_iam_role_policy.ecs_task_execution.  Valid fake ARNs
#                     also make the execution policy assertions deterministic.
#
# module.observability → override_module: the module creates alarms, SNS topics,
#                     log metric filters, and a dashboard — all of which reference
#                     computed ARNs from other modules.  Overriding keeps these
#                     env-level tests focused on wiring, not observability internals
#                     (those are tested in modules/observability/tests/).
#
# aws_sns_topic.billing_alarm
#                   → override_resource: mock-generated arn ("wr16sars") fails
#                     alarm_actions ARN validation on aws_cloudwatch_metric_alarm.
#
# data sources      → override_data: aws_caller_identity and aws_region return
#                     null attributes from the mock provider, which would produce
#                     invalid ARN strings in resource policies.

mock_provider "aws" {}

variables {
  project_name      = "test"
  environment       = "dev"
  github_org        = "myorg"
  github_repo       = "myrepo"
  state_bucket_name = "test-tfstate-123456789"
  db_username       = "platform_app"
  db_name           = "platform"
  alert_email       = "test@example.com"
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
      db_endpoint             = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id          = "db-AAAAAAAAAAAAAAAAAAAAA"
      db_arn                  = "arn:aws:rds:us-east-1:123456789012:db:test-dev-postgres"
      db_instance_identifier  = "test-dev-postgres"
      port                    = 5432
      database_name           = "platform"
      db_username             = "platform_app"
      master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test"
      ecs_cluster_name       = "test-dev"
      ecs_service_name       = "test-dev"
      task_definition_family = "test-dev"
      alb_dns_name           = "test-dev-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-dev/1234567890abcdef"
      tg_arn_suffix          = "test-dev/1234567890abcdef"
      log_group_name         = "/ecs/test-dev"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-dev"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      dashboard_name   = "CVSPlatformDev"
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

# ── ECS task policy: rds-db:connect must be scoped to one instance + user ─────
#
# rds-db:connect on Resource="*" would allow the app to authenticate as any
# username against any RDS instance in the account.  The ARN must be scoped
# to this environment's instance resource ID and the specific app DB username.

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
      db_endpoint            = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-AAAAAAAAAAAAAAAAAAAAA"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-dev-postgres"
      db_instance_identifier = "test-dev-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test"
      ecs_cluster_name       = "test-dev"
      ecs_service_name       = "test-dev"
      task_definition_family = "test-dev"
      alb_dns_name           = "test-dev-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-dev/1234567890abcdef"
      tg_arn_suffix          = "test-dev/1234567890abcdef"
      log_group_name         = "/ecs/test-dev"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-dev"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      dashboard_name   = "CVSPlatformDev"
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
    error_message = "rds-db:connect must never be granted on Resource='*'. Scope to the exact RDS instance resource ID ARN."
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

  # The resource ARN must embed the instance resource ID — not a wildcard instance.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "rds-db:connect") &&
      can(regex("dbuser:db-", tostring(s.Resource)))
    ])
    error_message = "rds-db:connect Resource must contain 'dbuser:db-<resource_id>' to identify the specific RDS instance."
  }
}

# ── ECS task policy: Secrets Manager must not expose the RDS master cred ──────
#
# The RDS master credential lives in the rds!* Secrets Manager namespace
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
      db_endpoint            = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-AAAAAAAAAAAAAAAAAAAAA"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-dev-postgres"
      db_instance_identifier = "test-dev-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test"
      ecs_cluster_name       = "test-dev"
      ecs_service_name       = "test-dev"
      task_definition_family = "test-dev"
      alb_dns_name           = "test-dev-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-dev/1234567890abcdef"
      tg_arn_suffix          = "test-dev/1234567890abcdef"
      log_group_name         = "/ecs/test-dev"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-dev"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      dashboard_name   = "CVSPlatformDev"
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

  # GetSecretValue must NOT cover the RDS master credential (rds!* namespace).
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task.policy).Statement :
      contains(tolist(s.Action), "secretsmanager:GetSecretValue") &&
      can(regex("secret:rds!", tostring(s.Resource)))
    ])
    error_message = "secretsmanager:GetSecretValue must NOT be granted on rds!* secrets. The app never reads the RDS master credential."
  }
}

# ── ECS task execution policy: ECR and CloudWatch access must be scoped ───────
#
# ecr:GetAuthorizationToken legitimately requires Resource="*" (AWS limitation —
# the API authenticates to the registry as a whole, not to a specific repository).
# All other ECR and CloudWatch permissions must be scoped to project ARNs.

run "ecs_task_execution_policy_scoped" {
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
      db_endpoint            = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-AAAAAAAAAAAAAAAAAAAAA"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-dev-postgres"
      db_instance_identifier = "test-dev-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test"
      ecs_cluster_name       = "test-dev"
      ecs_service_name       = "test-dev"
      task_definition_family = "test-dev"
      alb_dns_name           = "test-dev-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-dev/1234567890abcdef"
      tg_arn_suffix          = "test-dev/1234567890abcdef"
      log_group_name         = "/ecs/test-dev"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-dev"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      dashboard_name   = "CVSPlatformDev"
    }
  }

  override_resource {
    target = aws_sns_topic.billing_alarm
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:test-dev-billing-alarm"
    }
  }

  # ECRAuthToken legitimately requires Resource="*" — assert it IS present with
  # that resource so we catch any future tightening that breaks ECR auth.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task_execution.policy).Statement :
      s.Sid == "ECRAuthToken" &&
      contains(tolist(s.Action), "ecr:GetAuthorizationToken") &&
      tostring(s.Resource) == "*"
    ])
    error_message = "ECRAuthToken statement must grant ecr:GetAuthorizationToken on Resource='*'. AWS requires the wildcard — there is no repository-level ARN for this API call."
  }

  # ECR image pull (BatchGetImage etc.) must be scoped to the specific ECR
  # repository — not a wildcard that would permit pulling from any repository
  # in the account (including repositories owned by other teams).
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task_execution.policy).Statement :
      contains(tolist(s.Action), "ecr:BatchGetImage") &&
      tostring(s.Resource) == "*"
    ])
    error_message = "ecr:BatchGetImage must not be granted on Resource='*'. Scope to the specific ECR repository ARN to prevent pulling images from other repositories."
  }

  # CloudWatch log writes must be scoped to the ECS log group — not a wildcard
  # that would allow writing to any log group in the account.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_iam_role_policy.ecs_task_execution.policy).Statement :
      contains(tolist(s.Action), "logs:PutLogEvents") &&
      tostring(s.Resource) == "*"
    ])
    error_message = "logs:PutLogEvents must not be granted on Resource='*'. Scope to the specific CloudWatch log group ARN."
  }
}

# ── Operational alerts topic must be separate from the billing alarm topic ────
#
# Different subscribers (on-call eng vs finance), different urgency, different
# action — these must always be distinct SNS topics.  This run verifies that
# module.observability outputs a different ARN from the root-level billing alarm
# topic, catching any accidental reuse of the billing topic for service alerts.

run "sns_topics_are_separate" {
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
      db_endpoint            = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-AAAAAAAAAAAAAAAAAAAAA"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-dev-postgres"
      db_instance_identifier = "test-dev-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-AAAAAAAAAAAAAAAAAAAAA-BBBBBB"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test"
      ecs_cluster_name       = "test-dev"
      ecs_service_name       = "test-dev"
      task_definition_family = "test-dev"
      alb_dns_name           = "test-dev-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-dev/1234567890abcdef"
      tg_arn_suffix          = "test-dev/1234567890abcdef"
      log_group_name         = "/ecs/test-dev"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-dev"
    }
  }

  # module.observability is NOT fully overridden here — it runs with mock_provider
  # so the alerts SNS topic is a real (mock) resource. This gives the assertion
  # below genuine meaning: it fails if someone wires alerts_topic_arn to the
  # billing alarm topic instead of creating a new one.
  #
  # override_resource is required on the alerts SNS topic because mock_provider
  # returns a random short string (e.g. "1usfbxqa") for computed ARNs — not a
  # valid ARN. That invalid string then fails ARN validation in alarm_actions and
  # topic_arn on dependent resources. Supplying a valid fake ARN here unblocks
  # those validations while keeping the assertion meaningful: if someone wires the
  # observability module to emit the billing topic ARN, the two ARNs will match
  # and the assertion will fail.
  #
  # override_data for the module-internal data sources is also required:
  # the dashboard templatefile calls replace(data.aws_region.current.name, ...) —
  # which panics if the mock provider returns null for the name attribute.

  override_data {
    target = module.observability.data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = module.observability.data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  override_resource {
    target = module.observability.aws_sns_topic.alerts
    values = {
      arn  = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      name = "test-dev-alerts"
    }
  }

  override_resource {
    target = aws_sns_topic.billing_alarm
    values = {
      arn = "arn:aws:sns:us-east-1:123456789012:test-dev-billing-alarm"
    }
  }

  assert {
    condition     = module.observability.alerts_topic_arn != aws_sns_topic.billing_alarm.arn
    error_message = "Operational alerts topic ARN must differ from the billing alarm topic ARN. These are separate SNS topics with different subscribers and urgency levels."
  }
}
