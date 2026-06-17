# ── Identity ──────────────────────────────────────────────────────────────────

variable "project_name" {
  description = "Short slug used as a resource-name prefix (e.g. 'cvs-platform')."
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod). Used for naming and tagging."
  type        = string
}

# ── Alert routing ─────────────────────────────────────────────────────────────

variable "alert_email" {
  description = <<-EOT
    Email address to subscribe to the operational alerts SNS topic.
    AWS sends a confirmation email after apply — the subscription is pending
    (no alerts fire) until the recipient clicks the confirmation link.
  EOT
  type        = string
  sensitive   = true
}

# ── ECS ───────────────────────────────────────────────────────────────────────

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster (e.g. 'cvs-platform-dev'). Used as a CloudWatch metric dimension."
  type        = string
}

variable "ecs_service_name" {
  description = "Name of the ECS service (e.g. 'cvs-platform-dev'). Used as a CloudWatch metric dimension."
  type        = string
}

# ── ALB ───────────────────────────────────────────────────────────────────────

variable "alb_arn_suffix" {
  description = <<-EOT
    ARN suffix of the Application Load Balancer, e.g.
    'app/cvs-platform-dev/d17065f08d975205'.
    This is the portion after 'loadbalancer/' in the full ALB ARN — CloudWatch
    uses this as the LoadBalancer dimension value for AWS/ApplicationELB metrics.
  EOT
  type        = string
}

variable "tg_arn_suffix" {
  description = <<-EOT
    ARN suffix of the ALB target group, e.g.
    'cvs-platform-dev/917afdbb7305ea79'.
    This is the portion after 'targetgroup/' in the full TG ARN — required as the
    TargetGroup dimension for HealthyHostCount and other target-level ALB metrics.
  EOT
  type        = string
}

# ── RDS ───────────────────────────────────────────────────────────────────────

variable "rds_instance_identifier" {
  description = "RDS DB instance identifier (e.g. 'cvs-platform-dev-postgres'). Used as the DBInstanceIdentifier CloudWatch dimension."
  type        = string
}

# ── CloudWatch Logs ───────────────────────────────────────────────────────────

variable "log_group_name" {
  description = "Name of the CloudWatch log group that receives ECS task logs (e.g. '/ecs/cvs-platform-dev'). The metric filter for SecretProvisioningFailures is attached here."
  type        = string
}
