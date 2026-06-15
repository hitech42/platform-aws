variable "project_name" {
  description = "Short slug used as a prefix for all KMS resources (e.g. 'cvs-platform')."
  type        = string
}

variable "environment" {
  description = "Deployment environment — drives key alias and tagging."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "ecs_task_role_arn" {
  description = <<-EOT
    ARN of the ECS task role (the application container's IAM role).
    Granted kms:Decrypt and kms:GenerateDataKey in the key policy so the app
    can read and write CMK-encrypted Secrets Manager secrets at runtime.
    Comes from the iam module output: module.iam.ecs_task_role_arn.
  EOT
  type        = string
}
