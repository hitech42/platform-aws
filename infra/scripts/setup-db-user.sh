#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup-db-user.sh — one-time IAM database user bootstrap
#
# Creates the application Postgres user and grants it the rds_iam role so the
# app can authenticate via IAM token (no password).  Run once after the Aurora
# cluster is first provisioned, and again if you ever recreate the cluster.
#
# Uses the RDS Data API (aws rds-data execute-statement) — no VPC access, no
# bastion, no psql installation required.  Only AWS credentials with the
# permissions listed below are needed.
#
# Required IAM permissions for the caller:
#   rds-data:ExecuteStatement  on the cluster ARN
#   secretsmanager:GetSecretValue  on the master secret ARN
#   (both outputs from infra/envs/dev)
#
# Prerequisites: aws CLI ≥ 2.x, terraform (to read outputs)
#
# Usage (run from the repo root):
#   bash infra/scripts/setup-db-user.sh [ENV_DIR]
#
# ENV_DIR defaults to infra/envs/dev.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV_DIR="${1:-infra/envs/dev}"

echo "==> Reading Terraform outputs from ${ENV_DIR} ..."
CLUSTER_ARN=$(terraform -chdir="${ENV_DIR}" output -raw aurora_cluster_arn)
MASTER_SECRET_ARN=$(terraform -chdir="${ENV_DIR}" output -raw aurora_master_secret_arn)
DB_NAME=$(terraform -chdir="${ENV_DIR}" output -raw aurora_database_name)
DB_USERNAME=$(terraform -chdir="${ENV_DIR}" output -raw db_username)
AWS_REGION=$(terraform -chdir="${ENV_DIR}" output -raw aws_region 2>/dev/null || echo "us-east-1")

echo "    Cluster ARN : ${CLUSTER_ARN}"
echo "    DB name     : ${DB_NAME}"
echo "    App user    : ${DB_USERNAME}"
echo ""

# ── Step 1: create the application user (idempotent) ──────────────────────────
# We deliberately let the CREATE USER fail silently if the user already exists
# rather than using a DO block, because the Data API is simpler with flat SQL.
echo "==> Creating user '${DB_USERNAME}' (no-op if already exists) ..."
aws rds-data execute-statement \
  --region "${AWS_REGION}" \
  --resource-arn "${CLUSTER_ARN}" \
  --secret-arn "${MASTER_SECRET_ARN}" \
  --database "${DB_NAME}" \
  --sql "CREATE USER ${DB_USERNAME}" \
  --output json > /dev/null 2>&1 \
  || echo "    Note: user '${DB_USERNAME}' already exists — skipping CREATE."

# ── Step 2: grant rds_iam (idempotent) ───────────────────────────────────────
# GRANT is safe to run multiple times — Postgres ignores duplicate grants.
echo "==> Granting rds_iam role to '${DB_USERNAME}' ..."
aws rds-data execute-statement \
  --region "${AWS_REGION}" \
  --resource-arn "${CLUSTER_ARN}" \
  --secret-arn "${MASTER_SECRET_ARN}" \
  --database "${DB_NAME}" \
  --sql "GRANT rds_iam TO ${DB_USERNAME}" \
  --output json > /dev/null

echo ""
echo "==> Done."
echo "    '${DB_USERNAME}' can now authenticate via IAM token (no password)."
echo ""
echo "    To verify:"
echo "    aws rds-data execute-statement \\"
echo "      --resource-arn '${CLUSTER_ARN}' \\"
echo "      --secret-arn '${MASTER_SECRET_ARN}' \\"
echo "      --database '${DB_NAME}' \\"
echo "      --sql \"SELECT rolname, rolinherit FROM pg_roles WHERE rolname = '${DB_USERNAME}'\""
