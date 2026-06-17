# ── envs/dev configuration ────────────────────────────────────────────────────
# Fill in the REPLACE_WITH_* placeholders before running terraform init/plan.
# Commit this file — it contains no secrets (state bucket name includes your
# AWS account ID, which is low-sensitivity; rotate if your threat model differs).

project_name = "cvs-platform"
aws_region   = "us-east-1"
environment  = "dev"

# GitHub — replace with your actual org and repo name.
# Must match the canonical-case login exactly (GitHub logins are case-insensitive
# for URLs/git, but the OIDC token's `sub` claim uses the canonical-case login —
# verify with `gh api users/<name> --jq .login`). A case mismatch here causes
# AssumeRoleWithWebIdentity to fail with "Not authorized" even though the role
# ARN and condition values look correct at a glance.
github_org  = "hitech42"
github_repo = "platform-aws"

# Set to false if the GitHub OIDC provider already exists in this AWS account
# (you'll get an EntityAlreadyExists error on plan if it does).
create_oidc_provider = true

# Which branch is allowed to deploy to dev. Keep this locked to develop.
allowed_refs = ["refs/heads/develop"]

# From bootstrap outputs — fill in after running `terraform apply` in infra/bootstrap/.
# Must also be copied into backend.tf (backend config does not support variables).
state_bucket_name = "cvs-platform-tfstate-us-east-1-cae3b4ba"

# ── Database (module defaults match these values; explicit for clarity) ────────
db_name     = "platform"
db_username = "platform_app"

# ── Observability ─────────────────────────────────────────────────────────────
# Email address for operational (service) alerts.
# After terraform apply, AWS sends a confirmation email — alerts are silently
# dropped until the recipient clicks the confirmation link. Confirm immediately.
alert_email = "zimbalar42@gmail.com"

# ── Billing alarm ─────────────────────────────────────────────────────────────
# Alert fires when estimated AWS charges exceed this USD amount per day.
# Set this BEFORE applying any billable resources (KMS key, RDS instance).
# Subscribe your email after first apply:
#   aws sns subscribe \
#     --topic-arn $(terraform -chdir=infra/envs/dev output -raw billing_alarm_topic_arn) \
#     --protocol email \
#     --notification-endpoint your@email.com
billing_alarm_threshold = 20
