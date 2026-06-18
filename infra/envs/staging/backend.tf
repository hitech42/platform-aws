# ── Remote state backend ──────────────────────────────────────────────────────
#
# Same S3 bucket as dev — one state bucket serves all environments.
# The key is unique per environment so the state files never collide.
#
# State locking uses S3 native locking (use_lockfile = true, Terraform ≥ 1.10).
# No DynamoDB table is required.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  backend "s3" {
    bucket       = "cvs-platform-tfstate-us-east-1-cae3b4ba"
    key          = "envs/staging/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
