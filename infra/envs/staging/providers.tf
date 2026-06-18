terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Apply project/environment tags to every resource that supports tags.
  # Module-level tags are merged on top of these (module tags take precedence
  # for duplicate keys, allowing per-resource Name overrides).
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
