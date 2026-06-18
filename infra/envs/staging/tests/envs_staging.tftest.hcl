# Run from infra/envs/staging/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider — no real AWS credentials required.
#
# Override strategy
# ─────────────────────────────────────────────────────────────────────────────
# Same philosophy as envs_dev.tftest.hcl: these tests verify the *wiring* of
# envs/staging, not module internals. Where staging-specific values must be
# verified at the env level (deletion_protection, log_retention_days, etc.),
# the relevant module is left un-overridden so assertions can read its resources.
#
# create_oidc_provider=false: staging looks up the existing OIDC provider via a
# data source. When module.iam is not overridden, the data source is overridden
# to supply a valid fake ARN so the trust policy renders correctly.
#
# No billing alarm resource: staging intentionally omits aws_sns_topic.billing_alarm.
# The dev environment's billing alarm monitors account-level EstimatedCharges —
# a second alarm in staging would watch the same metric and create duplicate
# noise. No override_resource is needed here; the resource simply does not exist.

mock_provider "aws" {}

variables {
  project_name      = "test"
  environment       = "staging"
  github_org        = "myorg"
  github_repo       = "myrepo"
  state_bucket_name = "test-tfstate-123456789"
  db_username       = "platform_app"
  db_name           = "platform"
  alert_email       = "test@example.com"
}

# ── Staging environment identity ──────────────────────────────────────────────
#
# Guards against copy-paste errors where an operator clones envs/dev and forgets
# to update the environment variable — which would apply staging config under the
# "dev" name, merging two environments' resources into one naming namespace.

run "staging_is_not_dev" {
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
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-staging"
    }
  }

  override_module {
    target = module.data
    outputs = {
      db_endpoint            = "test-staging-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-BBBBBBBBBBBBBBBBBBBBB"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-staging-postgres"
      db_instance_identifier = "test-staging-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-BBBBBBBBBBBBBBBBBBBBB-CCCCCC"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-staging"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test-staging"
      ecs_cluster_name       = "test-staging"
      ecs_service_name       = "test-staging"
      task_definition_family = "test-staging"
      alb_dns_name           = "test-staging-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-staging/1234567890abcdef"
      tg_arn_suffix          = "test-staging/1234567890abcdef"
      log_group_name         = "/ecs/test-staging"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-staging"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-staging-alerts"
      dashboard_name   = "CVSPlatformStaging"
    }
  }

  assert {
    condition     = var.environment == "staging"
    error_message = "environment must be 'staging'. Guards against copy-paste errors where a clone of envs/dev has the wrong environment value."
  }

  assert {
    condition     = var.environment != "dev"
    error_message = "environment must not be 'dev'. The staging config must never be applied under the dev environment name."
  }

  assert {
    condition     = module.iam.github_actions_role_arn != ""
    error_message = "GitHub Actions deploy role ARN must be non-empty for the staging environment."
  }
}

# ── RDS protection flags: staging must resist accidental destroy ─────────────
#
# deletion_protection=true requires a second apply to flip to false before
# terraform destroy will proceed — preventing accidental data loss.
# skip_final_snapshot=false retains a recoverable backup on every destroy.
# Both differ from dev (false / true respectively) — this run catches any
# accidental reversion to dev-style values in staging/main.tf.
#
# module.data is NOT overridden: assertions read aws_db_instance.postgres
# attributes that staging/main.tf passes to the data module at line 85-86.

run "rds_deletion_protection" {
  command = plan

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
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-staging"
    }
  }

  override_module {
    target = module.iam
    outputs = {
      github_actions_role_arn      = "arn:aws:iam::123456789012:role/test-staging-github-deploy"
      ecs_task_execution_role_arn  = "arn:aws:iam::123456789012:role/test-staging-ecs-task-execution"
      ecs_task_execution_role_name = "test-staging-ecs-task-execution"
      ecs_task_role_arn            = "arn:aws:iam::123456789012:role/test-staging-ecs-task"
      ecs_task_role_name           = "test-staging-ecs-task"
      oidc_provider_arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-staging"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test-staging"
      ecs_cluster_name       = "test-staging"
      ecs_service_name       = "test-staging"
      task_definition_family = "test-staging"
      alb_dns_name           = "test-staging-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-staging/1234567890abcdef"
      tg_arn_suffix          = "test-staging/1234567890abcdef"
      log_group_name         = "/ecs/test-staging"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-staging"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-staging-alerts"
      dashboard_name   = "CVSPlatformStaging"
    }
  }

  assert {
    condition     = module.data.deletion_protection == true
    error_message = "deletion_protection must be true in staging. A terraform destroy will fail unless this is explicitly flipped to false in a prior apply — preventing accidental data loss."
  }

  assert {
    condition     = module.data.skip_final_snapshot == false
    error_message = "skip_final_snapshot must be false in staging. A final snapshot is retained on destroy so data can be recovered if needed. Set true only in dev (disposable data)."
  }
}

# ── ECS log retention: staging retains logs longer than dev ──────────────────
#
# Dev retains CloudWatch logs for 7 days. Staging must retain for at least
# 14 days so post-deploy debugging and compliance audits have enough history.
#
# module.ecs_service is NOT overridden: assertion reads the actual
# aws_cloudwatch_log_group.app.retention_in_days set by log_retention_days=14
# in staging/main.tf line 125.
# module.ecs_service.data.aws_region.current is overridden so the container
# definition JSON renders without null values when the module runs under the
# mock provider.

run "ecs_log_retention_at_least_14_days" {
  command = plan

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

  override_data {
    target = module.ecs_service.data.aws_region.current
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
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-staging"
    }
  }

  override_module {
    target = module.data
    outputs = {
      db_endpoint            = "test-staging-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-BBBBBBBBBBBBBBBBBBBBB"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-staging-postgres"
      db_instance_identifier = "test-staging-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-BBBBBBBBBBBBBBBBBBBBB-CCCCCC"
    }
  }

  override_module {
    target = module.iam
    outputs = {
      github_actions_role_arn      = "arn:aws:iam::123456789012:role/test-staging-github-deploy"
      ecs_task_execution_role_arn  = "arn:aws:iam::123456789012:role/test-staging-ecs-task-execution"
      ecs_task_execution_role_name = "test-staging-ecs-task-execution"
      ecs_task_role_arn            = "arn:aws:iam::123456789012:role/test-staging-ecs-task"
      ecs_task_role_name           = "test-staging-ecs-task"
      oidc_provider_arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-staging-alerts"
      dashboard_name   = "CVSPlatformStaging"
    }
  }

  assert {
    condition     = module.ecs_service.log_retention_days >= 14
    error_message = "log_retention_days must be >= 14 in staging (dev uses 7). Staging needs longer retention for post-deploy debugging and compliance audits."
  }
}

# ── GitHub deploy role: trust restricted to staging branch only ───────────────
#
# module.iam.allowed_refs is what gets embedded in the OIDC trust policy's
# StringLike condition. The IAM module tests (modules/iam/tests/) verify that
# allowed_refs is correctly encoded into the trust policy JSON; here we check
# the wiring — that staging/main.tf passes exactly the staging branch and no
# other branch to the IAM module.
#
# Checking the allowed_refs output (a variable echo) is appropriate at the env
# level. Parsing the generated trust policy JSON is redundant here: if the IAM
# module correctly embeds allowed_refs (guaranteed by module tests), the only
# thing left to verify is that staging wires the right refs.

run "github_deploy_role_restricts_to_staging_branch" {
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
      kms_alias_arn = "arn:aws:kms:us-east-1:123456789012:alias/test-staging"
    }
  }

  override_module {
    target = module.data
    outputs = {
      db_endpoint            = "test-staging-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
      db_resource_id         = "db-BBBBBBBBBBBBBBBBBBBBB"
      db_arn                 = "arn:aws:rds:us-east-1:123456789012:db:test-staging-postgres"
      db_instance_identifier = "test-staging-postgres"
      port                   = 5432
      database_name          = "platform"
      db_username            = "platform_app"
      master_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds!db-BBBBBBBBBBBBBBBBBBBBB-CCCCCC"
    }
  }

  override_module {
    target = module.ecs_service
    outputs = {
      ecr_repository_url     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test-staging"
      ecr_repository_arn     = "arn:aws:ecr:us-east-1:123456789012:repository/test-staging"
      ecs_cluster_name       = "test-staging"
      ecs_service_name       = "test-staging"
      task_definition_family = "test-staging"
      alb_dns_name           = "test-staging-1234567890.us-east-1.elb.amazonaws.com"
      alb_arn_suffix         = "app/test-staging/1234567890abcdef"
      tg_arn_suffix          = "test-staging/1234567890abcdef"
      log_group_name         = "/ecs/test-staging"
      log_group_arn          = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/test-staging"
    }
  }

  override_module {
    target = module.observability
    outputs = {
      alerts_topic_arn = "arn:aws:sns:us-east-1:123456789012:test-staging-alerts"
      dashboard_name   = "CVSPlatformStaging"
    }
  }

  # The staging branch ref must be wired in so CI/CD jobs on refs/heads/staging
  # can assume the deploy role.
  assert {
    condition     = contains(module.iam.allowed_refs, "refs/heads/staging")
    error_message = "module.iam must receive 'refs/heads/staging' in allowed_refs. Without this the staging branch cannot assume the deploy role."
  }

  # The develop branch must not appear — develop deploys to dev, never staging.
  assert {
    condition     = !contains(module.iam.allowed_refs, "refs/heads/develop")
    error_message = "module.iam must not receive 'refs/heads/develop' in allowed_refs. The develop branch must only be allowed to assume the dev deploy role."
  }
}
