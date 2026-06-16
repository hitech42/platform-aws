# ── Identity ──────────────────────────────────────────────────────────────────

variable "project_name" {
  description = "Short slug used as a prefix for all resources (e.g. 'cvs-platform')."
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources in this environment."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment. Drives resource naming, tagging, and IAM trust conditions."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────

variable "github_org" {
  description = "GitHub organisation or user that owns the repository (e.g. 'hitech42')."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the org prefix (e.g. 'platform-aws')."
  type        = string
}

variable "create_oidc_provider" {
  description = "Set to false if the GitHub Actions OIDC provider already exists in this AWS account."
  type        = bool
  default     = true
}

variable "allowed_refs" {
  description = "GitHub ref patterns allowed to assume this environment's deploy role. Default: develop branch only."
  type        = list(string)
  default     = ["refs/heads/develop"]
}

# ── Bootstrap outputs ─────────────────────────────────────────────────────────
#
# Must match the value in backend.tf — Terraform cannot read its own backend
# config as a variable, so the bucket name is declared here separately to
# scope the IAM deploy-role S3 policy.

variable "state_bucket_name" {
  description = "Name of the S3 state bucket (from bootstrap output state_bucket_name)."
  type        = string
}

# ── Network overrides (optional — module defaults are suitable for dev) ───────

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Override the module default if 10.0.0.0/16 conflicts with existing networks."
  type        = string
  default     = "10.0.0.0/16"
}

# ── Database ──────────────────────────────────────────────────────────────────

variable "db_name" {
  description = "Name of the initial database in the RDS instance."
  type        = string
  default     = "platform"
}

variable "db_username" {
  description = "Username for the IAM-authenticated application DB user. Created by infra/scripts/setup-db-user.sh after the first apply — not the RDS master user (postgres)."
  type        = string
  default     = "platform_app"
}

# ── Billing alarm ─────────────────────────────────────────────────────────────

variable "billing_alarm_threshold" {
  description = "USD threshold for the CloudWatch estimated-charges billing alarm. Subscribe your email to the billing_alarm_topic_arn SNS output to receive alerts."
  type        = number
  default     = 20
}
