# ──────────────────────────────────────────────────────────────────────────────
# BOOTSTRAP — run once, manually, before any other Terraform in this repo.
#
# This module creates the S3 bucket that all other Terraform root modules
# (envs/dev, envs/staging, etc.) use as their remote state backend.
# State locking uses S3 native locking (use_lockfile = true, Terraform ≥ 1.10)
# — no DynamoDB table is needed.
#
# It cannot itself use a remote backend (chicken-and-egg), so state for this
# module is stored locally.  After applying:
#
#   1. Note the output (state_bucket_name).
#   2. Copy it into infra/envs/dev/backend.tf (and later staging/prod).
#   3. Run `terraform init` inside each env directory to migrate state there.
#
# Commands (run from infra/bootstrap/):
#   terraform init
#   terraform plan  -var="project_name=<your-project-slug>"
#   terraform apply -var="project_name=<your-project-slug>"
#
# Do NOT add this directory to CI — it is a one-time human-run operation.
# ──────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local backend — intentional.  This is the one module that cannot use
  # the remote state bucket because that bucket doesn't exist yet.
  # The resulting terraform.tfstate file should be committed (or stored
  # securely) so the bucket is never accidentally re-created.
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ── S3 remote-state bucket ────────────────────────────────────────────────────

resource "aws_s3_bucket" "tfstate" {
  # Include account ID to guarantee global uniqueness without a random suffix
  # (random suffixes are harder to communicate to the team).
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental destruction of the bucket that holds all Terraform state.
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name      = "${var.project_name}-tfstate"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption choice: SSE-S3 (AES-256, S3-managed keys).
#
# We use SSE-S3 rather than SSE-KMS here because:
#  1. The main application KMS key is created later (E2/E3), so there is no
#     suitable key to reference at bootstrap time.
#  2. Creating a separate KMS key just for state encryption adds cost (~$1/mo)
#     and an extra resource to manage, for minimal security gain: Terraform
#     state access is already controlled by IAM — the same identities that
#     can call s3:GetObject can also call kms:Decrypt, so KMS doesn't add
#     an independent access-control layer here.
#  3. SSE-S3 satisfies "encryption at rest" for compliance purposes and is
#     on by default for new buckets; this resource makes it explicit/auditable.
#
# Revisit if your organisation requires customer-managed keys for all S3
# buckets (some SOC-2 / PCI environments do).
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

