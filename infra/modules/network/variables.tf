variable "project_name" {
  description = "Short slug used as a prefix for all resources (e.g. 'cvs-platform')."
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

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of exactly 2 CIDR blocks for public subnets (one per AZ). Used by the ALB and ECS tasks."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly 2 public subnet CIDRs are required (one per AZ)."
  }
}

variable "private_subnet_cidrs" {
  description = "List of exactly 2 CIDR blocks for private subnets (one per AZ). Used by Aurora; no NAT Gateway, so no outbound internet from here."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.3.0/24"]
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly 2 private subnet CIDRs are required (one per AZ)."
  }
}

variable "app_port" {
  description = "Port the application container listens on. Used to open inbound on the ECS service security group."
  type        = number
  default     = 8000
}
