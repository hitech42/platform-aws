# Run from infra/modules/network/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider so no AWS credentials are required.
# override_data supplies mock AZ names for every run because the
# aws_availability_zones data source returns null computed attributes
# under the mock, which would cause element() to panic.

mock_provider "aws" {}

variables {
  project_name = "test"
  environment  = "dev"
}

# ── Subnet counts and IP-assignment behaviour ─────────────────────────────────

run "subnet_counts" {
  command = plan

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "Expected exactly 2 public subnets (one per AZ)."
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "Expected exactly 2 private subnets (one per AZ)."
  }
}

run "public_subnets_assign_public_ip" {
  command = plan

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # ECS tasks need public IPs to reach ECR/Secrets Manager/CloudWatch via the
  # IGW without a NAT Gateway.
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == true])
    error_message = "All public subnets must have map_public_ip_on_launch=true so ECS tasks can reach AWS APIs via IGW."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "Private subnets must not assign public IPs (Aurora does not need them)."
  }
}

# ── db_sg: Postgres inbound only from ecs_service_sg, never from a CIDR ───────

run "db_sg_restricted_inbound" {
  command = plan

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  # Exactly one ingress rule — no surprise open ports.
  assert {
    condition     = length(aws_security_group.db.ingress) == 1
    error_message = "db_sg must have exactly one ingress rule (Postgres from ECS tasks only)."
  }

  # That one rule must be on port 5432 only.
  assert {
    condition     = one(aws_security_group.db.ingress).from_port == 5432
    error_message = "db_sg ingress from_port must be 5432."
  }

  assert {
    condition     = one(aws_security_group.db.ingress).to_port == 5432
    error_message = "db_sg ingress to_port must be 5432 (no port range)."
  }

  # No CIDR-based inbound — the DB must never be reachable from an IP range,
  # only from the ECS service security group.
  # coalesce(..., []) handles the mock provider returning null for unset list
  # attributes (the real provider returns [] for unspecified cidr_blocks).
  assert {
    condition     = length(coalesce(one(aws_security_group.db.ingress).cidr_blocks, [])) == 0
    error_message = "db_sg must not allow inbound from any CIDR block. Inbound must be restricted to ecs_service_sg by security group reference, not IP range."
  }

  assert {
    condition     = length(coalesce(one(aws_security_group.db.ingress).ipv6_cidr_blocks, [])) == 0
    error_message = "db_sg must not allow inbound from any IPv6 CIDR block."
  }

  # Must reference exactly one source security group (ecs_service_sg).
  assert {
    condition     = length(one(aws_security_group.db.ingress).security_groups) == 1
    error_message = "db_sg ingress must reference exactly one source security group (ecs_service_sg)."
  }
}

# ── ecs_service_sg: app-port inbound only from alb_sg ────────────────────────

run "ecs_service_sg_restricted_inbound" {
  command = plan

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  assert {
    condition     = length(aws_security_group.ecs_service.ingress) == 1
    error_message = "ecs_service_sg must have exactly one ingress rule (app port from ALB only)."
  }

  # Inbound must be the app port (default 8000), not 0/0 or some other range.
  assert {
    condition     = one(aws_security_group.ecs_service.ingress).from_port == var.app_port
    error_message = "ecs_service_sg ingress from_port must equal var.app_port."
  }

  assert {
    condition     = one(aws_security_group.ecs_service.ingress).to_port == var.app_port
    error_message = "ecs_service_sg ingress to_port must equal var.app_port."
  }

  # No CIDR-based inbound — traffic must arrive via the ALB, not directly.
  assert {
    condition     = length(coalesce(one(aws_security_group.ecs_service.ingress).cidr_blocks, [])) == 0
    error_message = "ecs_service_sg must not allow inbound from any CIDR block. Traffic must come through the ALB security group only."
  }

  assert {
    condition     = length(one(aws_security_group.ecs_service.ingress).security_groups) == 1
    error_message = "ecs_service_sg ingress must reference exactly one source security group (alb_sg)."
  }
}
