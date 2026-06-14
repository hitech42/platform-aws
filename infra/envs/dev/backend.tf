# ── Remote state backend ──────────────────────────────────────────────────────
#
# SETUP REQUIRED: fill in the two placeholder values below with the outputs
# from infra/bootstrap/ BEFORE running `terraform init` in this directory.
#
#   cd infra/bootstrap/
#   terraform output state_bucket_name    → paste into `bucket`
#   terraform output state_lock_table_name → paste into `dynamodb_table`
#
# The `key` is intentionally unique per environment (envs/dev/) so multiple
# root modules can share the same bucket without colliding.
#
# Note: the S3 backend block does NOT support variable interpolation — values
# must be literal strings here (or supplied via -backend-config flags / envvars
# at `terraform init` time).
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  backend "s3" {
    bucket         = "REPLACE_WITH_bootstrap_state_bucket_name_output"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE_WITH_bootstrap_state_lock_table_name_output"
    encrypt        = true
  }
}
