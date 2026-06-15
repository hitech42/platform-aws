# ── envs/dev configuration ────────────────────────────────────────────────────
# Fill in the REPLACE_WITH_* placeholders before running terraform init/plan.
# Commit this file — it contains no secrets (state bucket name includes your
# AWS account ID, which is low-sensitivity; rotate if your threat model differs).

project_name = "cvs-platform"
aws_region   = "us-east-1"
environment  = "dev"

# GitHub — replace with your actual org and repo name.
github_org  = "HiTech42"
github_repo = "platform-aws"

# Set to false if the GitHub OIDC provider already exists in this AWS account
# (you'll get an EntityAlreadyExists error on plan if it does).
create_oidc_provider = true

# Which branch is allowed to deploy to dev. Keep this locked to develop.
allowed_refs = ["refs/heads/develop"]

# From bootstrap outputs — fill in after running `terraform apply` in infra/bootstrap/.
# Must also be copied into backend.tf (backend config does not support variables).
state_bucket_name = "cvs-platform-tfstate-874505351468"
