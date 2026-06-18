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
  default     = "staging"
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
  description = "Set to false for staging — the GitHub Actions OIDC provider is account-wide and was already created by the dev environment apply."
  type        = bool
  default     = false
}

variable "allowed_refs" {
  description = "GitHub ref patterns allowed to assume this environment's deploy role. Staging: staging branch only."
  type        = list(string)
  default     = ["refs/heads/staging"]
}

# ── Bootstrap outputs ─────────────────────────────────────────────────────────

variable "state_bucket_name" {
  description = "Name of the S3 state bucket (from bootstrap output state_bucket_name)."
  type        = string
}

# ── Network overrides (optional — module defaults are suitable for staging) ───

variable "vpc_cidr" {
  description = "CIDR block for the staging VPC. Staging gets its own VPC; same CIDR as dev is fine — they are not peered."
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
  description = "Username for the IAM-authenticated application DB user."
  type        = string
  default     = "platform_app"
}

# ── Observability ─────────────────────────────────────────────────────────────

variable "alert_email" {
  description = "Email address for operational alert SNS subscriptions. Requires manual confirmation after apply."
  type        = string
  sensitive   = true
}
