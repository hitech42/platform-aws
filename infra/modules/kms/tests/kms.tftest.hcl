# Run from infra/modules/kms/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider — no AWS credentials required.
# override_data supplies a fake account ID for the root principal ARN in the
# key policy (data.aws_caller_identity.current is unresolvable under the mock).

mock_provider "aws" {}

variables {
  project_name      = "test"
  environment       = "dev"
  ecs_task_role_arn = "arn:aws:iam::123456789012:role/test-dev-ecs-task"
}

# ── Key rotation and deletion window ─────────────────────────────────────────

run "key_rotation_enabled" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXXX"
    }
  }

  assert {
    condition     = aws_kms_key.platform.enable_key_rotation == true
    error_message = "KMS key must have automatic rotation enabled."
  }

  assert {
    condition     = aws_kms_key.platform.deletion_window_in_days <= 30
    error_message = "Deletion window must be 30 days or less (7 for dev)."
  }
}

# ── Key policy: required principals present ───────────────────────────────────
#
# command=apply because the key policy embeds data.aws_caller_identity.current.account_id
# which is unknown at plan time even with override_data when the policy is jsonencode().

run "key_policy_principals" {
  command = apply

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXXX"
    }
  }

  # Root account must be in the key policy.  Without this the key can never be
  # administered if all IAM policies granting key access are accidentally removed.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.platform.policy).Statement :
      try(s.Principal.AWS == "arn:aws:iam::123456789012:root", false)
    ])
    error_message = "Key policy must include the root account principal for break-glass admin access."
  }

  # RDS service principal must have CreateGrant so RDS can use the key for
  # storage encryption via key grants.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.platform.policy).Statement :
      try(s.Principal.Service == "rds.amazonaws.com", false) &&
      contains(tolist(s.Action), "kms:CreateGrant")
    ])
    error_message = "Key policy must allow rds.amazonaws.com kms:CreateGrant so RDS can encrypt storage."
  }

  # ECS task role must appear in the key policy with Decrypt access.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_kms_key.platform.policy).Statement :
      try(s.Principal.AWS == var.ecs_task_role_arn, false) &&
      contains(tolist(s.Action), "kms:Decrypt")
    ])
    error_message = "Key policy must grant kms:Decrypt to the ECS task role so the app can read encrypted secrets."
  }

  # ECS task role must NOT have kms:CreateGrant — it should only decrypt,
  # never create grants that could extend access to third parties.
  assert {
    condition = !anytrue([
      for s in jsondecode(aws_kms_key.platform.policy).Statement :
      try(s.Principal.AWS == var.ecs_task_role_arn, false) &&
      contains(tolist(s.Action), "kms:CreateGrant")
    ])
    error_message = "ECS task role must not have kms:CreateGrant — decrypt-only access is sufficient."
  }
}

# ── Alias naming convention ───────────────────────────────────────────────────

run "alias_naming" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXXX"
    }
  }

  assert {
    condition     = aws_kms_alias.platform.name == "alias/${var.project_name}-${var.environment}"
    error_message = "KMS alias must follow alias/{project_name}-{environment} naming convention."
  }
}
