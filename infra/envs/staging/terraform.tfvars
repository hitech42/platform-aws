# ── envs/staging configuration ────────────────────────────────────────────────
# Staging environment — deployed from the `staging` branch. Promotes from `develop`.
# Do not edit resource names manually — they are derived from the environment variable.
#
# To apply: cd infra/envs/staging && terraform init && terraform apply
# To scale ECS up for testing:
#   aws ecs update-service --cluster cvs-platform-staging \
#     --service cvs-platform-staging --desired-count 1 --profile cvs-platform
# To scale back down (cost saving):
#   aws ecs update-service --cluster cvs-platform-staging \
#     --service cvs-platform-staging --desired-count 0 --profile cvs-platform

project_name = "cvs-platform"
aws_region   = "us-east-1"
environment  = "staging"

github_org  = "hitech42"
github_repo = "platform-aws"

# OIDC provider is account-wide — already created by dev environment apply.
create_oidc_provider = false

# Only the staging branch can assume the staging deploy role.
allowed_refs = ["refs/heads/staging"]

# Same state bucket as dev — different key (envs/staging/terraform.tfstate).
state_bucket_name = "cvs-platform-tfstate-us-east-1-cae3b4ba"

# ── Database ──────────────────────────────────────────────────────────────────
db_name     = "platform"
db_username = "platform_app"

# ── Observability ─────────────────────────────────────────────────────────────
# Same email as dev for demo purposes.
# After terraform apply, confirm the SNS subscription email from AWS.
alert_email = "zimbalar42@gmail.com"
