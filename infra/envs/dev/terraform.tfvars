# ── envs/dev configuration ────────────────────────────────────────────────────
# Fill in the REPLACE_WITH_* placeholders before running terraform init/plan.
# Commit this file — it contains no secrets (state bucket name includes your
# AWS account ID, which is low-sensitivity; rotate if your threat model differs).

project_name = "cvs-platform"
aws_region   = "us-east-1"
environment  = "dev"

# GitHub — replace with your actual org and repo name.
github_org  = "REPLACE_WITH_YOUR_GITHUB_ORG"
github_repo = "REPLACE_WITH_YOUR_GITHUB_REPO"

# Set to false if the GitHub OIDC provider already exists in this AWS account
# (you'll get an EntityAlreadyExists error on plan if it does).
create_oidc_provider = true

# Which branch is allowed to deploy to dev. Keep this locked to develop.
allowed_refs = ["refs/heads/develop"]

# From bootstrap outputs — fill in after running `terraform apply` in infra/bootstrap/.
# These must also be copied into backend.tf (backend config does not support variables).
state_bucket_name     = "REPLACE_WITH_bootstrap_state_bucket_name_output"
state_lock_table_name = "REPLACE_WITH_bootstrap_state_lock_table_name_output"
