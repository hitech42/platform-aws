# Run from infra/envs/dev/:
#   terraform init -backend=false
#   terraform test

mock_provider "aws" {}

# ── environment variable validation ──────────────────────────────────────────

run "invalid_environment_rejected" {
  command = plan

  variables {
    project_name          = "test"
    environment           = "production" # not in ["dev", "staging", "prod"]
    github_org            = "myorg"
    github_repo           = "myrepo"
    state_bucket_name     = "test-tfstate-123456789"
    state_lock_table_name = "test-tfstate-lock"
  }

  # Variable validation runs before any module is instantiated, so no data
  # source overrides are needed here — the plan fails fast.
  expect_failures = [var.environment]
}

run "valid_environment_accepted" {
  command = apply # module.iam.github_actions_role_arn is a computed value, unknown at plan time

  variables {
    project_name          = "test"
    environment           = "dev"
    github_org            = "myorg"
    github_repo           = "myrepo"
    state_bucket_name     = "test-tfstate-123456789"
    state_lock_table_name = "test-tfstate-lock"
  }

  override_data {
    target = module.network.data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # The assertion here is implicit: if the plan succeeds, "dev" is accepted.
  # We spot-check one output to confirm the modules were actually instantiated.
  assert {
    condition     = module.iam.github_actions_role_arn != ""
    error_message = "GitHub Actions role ARN must be non-empty when environment is valid."
  }
}
