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
  description = "ARN of the platform CMK (from kms module). Used for Aurora storage encryption and the managed master credential in Secrets Manager."
  type        = string
}

# ── Network (from network module outputs) ─────────────────────────────────────

variable "private_subnet_ids" {
  description = "IDs of the two private subnets from the network module. Aurora requires at least 2 subnets in different AZs with no internet route."
  type        = list(string)
}

variable "db_sg_id" {
  description = "ID of the DB security group from the network module. Allows inbound port 5432 from ecs_service_sg only — no CIDR inbound."
  type        = string
}

# ── Database configuration ────────────────────────────────────────────────────

variable "db_name" {
  description = "Name of the initial database created in the Aurora cluster."
  type        = string
  default     = "platform"
}

variable "db_username" {
  description = <<-EOT
    Username for the IAM-authenticated application DB user.
    This is NOT the master/admin user (postgres) — it is a separate Postgres
    user granted the rds_iam role, created via a one-time SQL bootstrap script
    after the cluster is provisioned.  The app authenticates as this user using
    an IAM-generated auth token, never a password.
    See README.md "Infrastructure setup — IAM DB user bootstrap".
  EOT
  type        = string
  default     = "platform_app"
}

# ── Aurora Serverless v2 scaling ──────────────────────────────────────────────

variable "engine_version" {
  description = <<-EOT
    Aurora PostgreSQL engine version for Serverless v2.
    To list currently available versions:
      aws rds describe-db-engine-versions \
        --engine aurora-postgresql \
        --filters Name=status,Values=available \
        --query 'DBEngineVersions[?contains(SupportedEngineModes,`provisioned`)].EngineVersion'
  EOT
  type        = string
  default     = "16.4"
}

variable "enable_http_endpoint" {
  description = <<-EOT
    Enable the RDS Data API (HTTP endpoint) on the Aurora cluster.
    When true, SQL can be executed via `aws rds-data execute-statement` without
    a direct TCP connection into the VPC — required by the IAM DB user bootstrap
    script (infra/scripts/setup-db-user.sh).  Still requires IAM auth to use.
    Set false in staging/prod if your security policy prohibits Data API exposure.
  EOT
  type        = bool
  default     = true
}

variable "min_capacity" {
  description = "Minimum Aurora Serverless v2 capacity in ACUs (0.5 is the minimum). Aurora scales down to this when idle."
  type        = number
  default     = 0.5
}

variable "max_capacity" {
  description = "Maximum Aurora Serverless v2 capacity in ACUs. 1 ACU ≈ 2 GiB RAM. Keep at 1 for dev; raise to 4–16 for load testing or staging."
  type        = number
  default     = 1.0
}
