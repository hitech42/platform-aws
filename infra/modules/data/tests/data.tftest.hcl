# Run from infra/modules/data/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider — no AWS credentials or real Aurora cluster required.
# Assertions on user-specified attributes (storage_encrypted, scaling config, etc.)
# work with command=plan.  Computed attributes (cluster_resource_id, ARNs) are
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
    condition     = aws_rds_cluster.aurora.storage_encrypted == true
    error_message = "Aurora cluster must have storage_encrypted=true."
  }

  # Guard against accidentally using the AWS-managed "aws/rds" default key,
  # which would mean the cluster is not encrypted with our CMK.
  assert {
    condition     = aws_rds_cluster.aurora.kms_key_id == var.kms_key_arn
    error_message = "Aurora cluster must use the customer-managed KMS key, not the default aws/rds key."
  }
}

# ── IAM database authentication ───────────────────────────────────────────────

run "iam_db_auth_enabled" {
  command = plan

  assert {
    condition     = aws_rds_cluster.aurora.iam_database_authentication_enabled == true
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
    condition     = aws_rds_cluster.aurora.deletion_protection == false
    error_message = "deletion_protection must be false in dev to allow clean terraform destroy. Set true in staging/prod."
  }

  assert {
    condition     = aws_rds_cluster.aurora.skip_final_snapshot == true
    error_message = "skip_final_snapshot must be true in dev to avoid orphaned snapshots on destroy. Set false in staging/prod."
  }
}

# ── Serverless v2 scaling: cost guardrail ────────────────────────────────────
#
# max_capacity=1 ACU (≈2 GiB RAM) caps the dev cluster cost at ~$0.06/hr
# under sustained load.  This test prevents accidentally raising the cap
# without an explicit variable change and code review.

run "serverless_scaling_config" {
  command = plan

  assert {
    condition     = aws_rds_cluster.aurora.serverlessv2_scaling_configuration[0].min_capacity >= 0.5
    error_message = "min_capacity must be >= 0.5 ACU (AWS minimum for Serverless v2)."
  }

  assert {
    condition     = aws_rds_cluster.aurora.serverlessv2_scaling_configuration[0].max_capacity <= 1.0
    error_message = "max_capacity must be <= 1 ACU in dev to control costs. Raise this only for load testing, with explicit review."
  }
}

# ── Engine: provisioned mode (Serverless v2), not legacy serverless ───────────

run "engine_mode_provisioned" {
  command = plan

  assert {
    condition     = aws_rds_cluster.aurora.engine_mode == "provisioned"
    error_message = "Aurora Serverless v2 requires engine_mode='provisioned'. 'serverless' is the legacy v1 API."
  }

  assert {
    condition     = aws_rds_cluster.aurora.engine == "aurora-postgresql"
    error_message = "Engine must be aurora-postgresql."
  }
}

# ── Subnet group uses private subnets ─────────────────────────────────────────

run "subnet_group_uses_private_subnets" {
  command = plan

  assert {
    condition     = length(aws_db_subnet_group.aurora.subnet_ids) == 2
    error_message = "DB subnet group must include exactly 2 private subnets (one per AZ)."
  }
}
