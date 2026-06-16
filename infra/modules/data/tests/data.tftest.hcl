# Run from infra/modules/data/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider — no AWS credentials or real RDS instance required.
# Assertions on user-specified attributes (storage_encrypted, instance_class, etc.)
# work with command=plan.  Computed attributes (resource_id, ARNs) are
# not tested here; they are covered in the envs/dev integration test suite.

mock_provider "aws" {}

variables {
  project_name       = "test"
  environment        = "dev"
  kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/mrk-00000000000000000000000000000000"
  private_subnet_ids = ["subnet-aaaa0001", "subnet-bbbb0002"]
  db_sg_id           = "sg-cccc0003"
}

# ── Encryption: CMK, not the AWS-managed default ──────────────────────────────

run "storage_encrypted_with_cmk" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.storage_encrypted == true
    error_message = "RDS instance must have storage_encrypted=true."
  }

  # Guard against accidentally using the AWS-managed "aws/rds" default key,
  # which would mean the instance is not encrypted with our CMK.
  assert {
    condition     = aws_db_instance.postgres.kms_key_id == var.kms_key_arn
    error_message = "RDS instance must use the customer-managed KMS key, not the default aws/rds key."
  }
}

# ── IAM database authentication ───────────────────────────────────────────────

run "iam_db_auth_enabled" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.iam_database_authentication_enabled == true
    error_message = "IAM database authentication must be enabled — the app authenticates via IAM token, not a password."
  }
}

# ── Dev safety: clean destroy without snapshot ────────────────────────────────
#
# deletion_protection=false and skip_final_snapshot=true allow `terraform destroy`
# in dev without a manual override step or orphaned snapshots.
# Guard against accidentally inverting these (they default to the prod-safe values
# in some modules and would block a clean dev teardown).

run "dev_destroy_flags" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.deletion_protection == false
    error_message = "deletion_protection must be false in dev to allow clean terraform destroy. Set true in staging/prod."
  }

  assert {
    condition     = aws_db_instance.postgres.skip_final_snapshot == true
    error_message = "skip_final_snapshot must be true in dev to avoid orphaned snapshots on destroy. Set false in staging/prod."
  }
}

# ── Engine and instance class: free-tier guardrail ───────────────────────────
#
# db.t4g.micro + 20 GiB gp2 are within the AWS free-tier allowance.
# This test prevents accidentally upgrading to a paid instance class
# without an explicit variable change and code review.

run "engine_and_instance_class" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.engine == "postgres"
    error_message = "Engine must be postgres (standard RDS, not Aurora)."
  }

  assert {
    condition     = aws_db_instance.postgres.instance_class == "db.t4g.micro"
    error_message = "instance_class must be db.t4g.micro in dev (free-tier eligible). Raise only for load testing, with explicit review."
  }
}

# ── No public internet access ─────────────────────────────────────────────────
#
# The RDS instance lives in private subnets with no default route.
# publicly_accessible=false is a defence-in-depth layer on top of the subnet
# isolation and security group restrictions.

run "not_publicly_accessible" {
  command = plan

  assert {
    condition     = aws_db_instance.postgres.publicly_accessible == false
    error_message = "publicly_accessible must be false — the RDS instance must not be reachable from the internet."
  }
}

# ── Subnet group uses private subnets ─────────────────────────────────────────

run "subnet_group_uses_private_subnets" {
  command = plan

  assert {
    condition     = length(aws_db_subnet_group.postgres.subnet_ids) == 2
    error_message = "DB subnet group must include exactly 2 private subnets (one per AZ)."
  }
}
