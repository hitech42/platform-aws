# ── Remote state backend ──────────────────────────────────────────────────────
#
# SETUP REQUIRED: fill in the bucket placeholder below with the output from
# infra/bootstrap/ BEFORE running `terraform init` in this directory.
#
#   cd infra/bootstrap/
#   terraform output state_bucket_name    → paste into `bucket`
#
# State locking uses S3 native locking (use_lockfile = true, Terraform ≥ 1.10).
# No DynamoDB table is required — Terraform writes a .tflock object to the same
# bucket using a conditional PUT to prevent concurrent applies.
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
    bucket       = "cvs-platform-tfstate-874505351468"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
