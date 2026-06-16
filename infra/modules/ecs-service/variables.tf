variable "project_name" {
  description = "Short slug used as a prefix for all ECS/ECR resources (e.g. 'cvs-platform')."
  type        = string
}

variable "environment" {
  description = "Deployment environment — drives naming and tagging."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# ── Encryption ────────────────────────────────────────────────────────────────

variable "kms_key_arn" {
  description = "ARN of the platform CMK. Used for ECR image encryption and CloudWatch log group encryption."
  type        = string
}

# ── Network (from network module outputs) ─────────────────────────────────────

variable "vpc_id" {
  description = "ID of the VPC. Used for the ALB target group."
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of the two public subnets. ALB is placed here; ECS tasks also run here (no NAT Gateway required — tasks get public IPs and reach AWS APIs via IGW)."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ID of the ALB security group (accepts HTTP/80 from internet)."
  type        = string
}

variable "ecs_service_sg_id" {
  description = "ID of the ECS service security group (inbound from ALB only, outbound all)."
  type        = string
}

# ── IAM (from iam module outputs) ─────────────────────────────────────────────

variable "ecs_task_execution_role_arn" {
  description = "ARN of the ECS task execution role (used by ECS agent to pull images and write logs)."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ARN of the ECS task role (used by the application container for AWS API calls)."
  type        = string
}

# ── Database (from data module outputs) ───────────────────────────────────────

variable "db_endpoint" {
  description = "Hostname of the RDS PostgreSQL instance. Used to construct DATABASE_URL in the container environment."
  type        = string
}

variable "db_username" {
  description = "IAM-auth application DB username (platform_app). Used in DATABASE_URL — no password, IAM token is generated at runtime."
  type        = string
}

variable "db_name" {
  description = "Name of the PostgreSQL database. Used in DATABASE_URL."
  type        = string
  default     = "platform"
}

# ── Application ───────────────────────────────────────────────────────────────

variable "container_image" {
  description = <<-EOT
    Full ECR image URI for the application container, e.g.
    "874505351468.dkr.ecr.us-east-1.amazonaws.com/cvs-platform:abc1234".
    Terraform uses this only for the initial task definition.  Subsequent
    deployments are driven by the CI/CD pipeline (app-deploy.yml) which
    registers a new task definition revision with the commit-SHA-tagged image
    and updates the ECS service — Terraform state is not updated on each deploy.
  EOT
  type        = string
  default     = "placeholder"
}

variable "app_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 8000
}

variable "desired_count" {
  description = "Number of ECS task replicas. Keep at 1 for dev; autoscaling is a prod concern."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU). Minimum Fargate size — cost-conscious for dev; size up based on load testing for staging/prod."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB (512 = 0.5 GiB). Minimum Fargate size for cpu=256."
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days. 7 days for dev (lower cost); use 30–90 for staging/prod."
  type        = number
  default     = 7
}

variable "ecr_image_count_limit" {
  description = "Maximum number of tagged images to retain in ECR. Older images beyond this limit are expired automatically (cost/hygiene guardrail)."
  type        = number
  default     = 10
}
