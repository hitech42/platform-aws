variable "project_name" {
  description = "Short slug used as a prefix for all data-layer resources (e.g. 'cvs-platform')."
  type        = string
}

variable "environment" {
  description = "Deployment environment — drives naming, tagging, and safe-destroy behaviour."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ── Encryption ────────────────────────────────────────────────────────────────

variable "kms_key_arn" {
  description = "ARN of the platform CMK (from kms module). Used for RDS storage encryption and the managed master credential in Secrets Manager."
  type        = string
}

# ── Network (from network module outputs) ─────────────────────────────────────

variable "private_subnet_ids" {
  description = "IDs of the two private subnets from the network module. RDS requires at least 2 subnets in different AZs with no internet route."
  type        = list(string)
}

variable "db_sg_id" {
  description = "ID of the DB security group from the network module. Allows inbound port 5432 from ecs_service_sg only — no CIDR inbound."
  type        = string
}

# ── Database configuration ────────────────────────────────────────────────────

variable "engine_version" {
  description = <<-EOT
    PostgreSQL engine version for the RDS instance.
    To list currently available versions:
      aws rds describe-db-engine-versions \
        --engine postgres \
        --filters Name=status,Values=available \
        --query 'DBEngineVersions[].EngineVersion'
  EOT
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Name of the initial database created in the RDS instance."
  type        = string
  default     = "platform"
}

variable "db_username" {
  description = <<-EOT
    Username for the IAM-authenticated application DB user.
    This is NOT the master/admin user (postgres) — it is a separate Postgres
    user granted the rds_iam role, created via a one-time SQL bootstrap script
    after the instance is provisioned.  The app authenticates as this user using
    an IAM-generated auth token, never a password.
    See infra/scripts/setup-db-user.sh.
  EOT
  type        = string
  default     = "platform_app"
}

# ── Lifecycle / safety ────────────────────────────────────────────────────────

variable "deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance. Set false for dev (fast teardown), true for staging/prod (requires a second apply to remove before destroy)."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final DB snapshot on destroy. Set true for dev (clean teardown), false for staging/prod (retain last backup before any destroy)."
  type        = bool
  default     = true
}
