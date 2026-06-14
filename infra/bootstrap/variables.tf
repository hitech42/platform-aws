variable "project_name" {
  description = "Short slug used as a prefix for all bootstrap resources (e.g. 'cvs-platform'). Must be globally unique when combined with the AWS account ID for the S3 bucket name."
  type        = string
}

variable "aws_region" {
  description = "AWS region for the bootstrap resources."
  type        = string
  default     = "us-east-1"
}
