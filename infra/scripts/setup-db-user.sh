#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup-db-user.sh — one-time IAM database user bootstrap
#
# Creates the application Postgres user and grants it the rds_iam role so the
# app can authenticate via IAM token (no password).  Run once after the RDS
# instance is first provisioned, and again if you ever recreate the instance.
#
# !! NETWORK ACCESS REQUIRED !!
# Standard RDS does not have a Data API.  This script connects via psql and
# must be run from a host with TCP access to the RDS instance on port 5432:
#   - An EC2 bastion or ECS Fargate task in the same VPC, OR
#   - After E3: run as a one-off Fargate task (recommended for automation).
#
# Required IAM permissions for the caller:
#   secretsmanager:GetSecretValue  on the master secret ARN (rds!* namespace)
#   (output: master_secret_arn from infra/envs/dev)
#
# Required tools: aws CLI >= 2.x, psql, jq, terraform (to read outputs)
#
# Usage (run from the repo root):
#   bash infra/scripts/setup-db-user.sh [ENV_DIR]
#
# ENV_DIR defaults to infra/envs/dev.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV_DIR="${1:-infra/envs/dev}"

echo "==> Reading Terraform outputs from ${ENV_DIR} ..."
DB_HOST=$(terraform -chdir="${ENV_DIR}" output -raw db_endpoint)
DB_PORT=$(terraform -chdir="${ENV_DIR}" output -raw db_port)
MASTER_SECRET_ARN=$(terraform -chdir="${ENV_DIR}" output -raw master_secret_arn)
DB_NAME=$(terraform -chdir="${ENV_DIR}" output -raw database_name)
DB_USERNAME=$(terraform -chdir="${ENV_DIR}" output -raw db_username)
AWS_REGION=$(terraform -chdir="${ENV_DIR}" output -raw aws_region 2>/dev/null || echo "us-east-1")

echo "    Host        : ${DB_HOST}:${DB_PORT}"
echo "    DB name     : ${DB_NAME}"
echo "    App user    : ${DB_USERNAME}"
echo ""

# ── Retrieve master password from Secrets Manager ─────────────────────────────
# AWS stores the master credential as JSON: {"username":"postgres","password":"..."}
echo "==> Retrieving master password from Secrets Manager ..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${AWS_REGION}" \
  --secret-id "${MASTER_SECRET_ARN}" \
  --query SecretString \
  --output text)

PGPASSWORD=$(echo "${SECRET_JSON}" | jq -r '.password')
PGMASTER=$(echo "${SECRET_JSON}" | jq -r '.username')
export PGPASSWORD

# ── Step 1: create the application user (idempotent) ──────────────────────────
echo "==> Creating user '${DB_USERNAME}' (no-op if already exists) ..."
psql \
  --host="${DB_HOST}" \
  --port="${DB_PORT}" \
  --username="${PGMASTER}" \
  --dbname="${DB_NAME}" \
  --command="DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USERNAME}') THEN
      CREATE USER ${DB_USERNAME};
    END IF;
  END \$\$;"

# ── Step 2: grant rds_iam (idempotent) ───────────────────────────────────────
# GRANT is safe to run multiple times — Postgres ignores duplicate grants.
echo "==> Granting rds_iam role to '${DB_USERNAME}' ..."
psql \
  --host="${DB_HOST}" \
  --port="${DB_PORT}" \
  --username="${PGMASTER}" \
  --dbname="${DB_NAME}" \
  --command="GRANT rds_iam TO ${DB_USERNAME};"

unset PGPASSWORD

echo ""
echo "==> Done."
echo "    '${DB_USERNAME}' can now authenticate via IAM token (no password)."
echo ""
echo "    To verify (requires VPC access):"
echo "    psql --host='${DB_HOST}' --port='${DB_PORT}' --username='${PGMASTER}' --dbname='${DB_NAME}' \\"
echo "      --command=\"SELECT rolname, rolinherit FROM pg_roles WHERE rolname = '${DB_USERNAME}'\""
