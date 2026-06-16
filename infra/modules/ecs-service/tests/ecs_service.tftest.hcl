# Run from infra/modules/ecs-service/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider so no AWS credentials are required.
#
# command=plan is used for assertions on attributes set directly in HCL
# (ALB internal flag, assign_public_ip, log retention, health check path,
# ECR mutability).  These are all known at plan time because the resource
# arguments come from input variables or hard-coded HCL values.
#
# command=apply is required for container_definitions: the healthCheck object
# is embedded in a jsonencode() call that includes data.aws_region.current.name,
# which is a computed value unknown at plan time.  override_data supplies a
# known region so the JSON string is fully resolved.

mock_provider "aws" {}

variables {
  project_name                = "test"
  environment                 = "dev"
  kms_key_arn                 = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  vpc_id                      = "vpc-00000000000000001"
  public_subnet_ids           = ["subnet-00000000000000001", "subnet-00000000000000002"]
  alb_sg_id                   = "sg-00000000000000001"
  ecs_service_sg_id           = "sg-00000000000000002"
  ecs_task_execution_role_arn = "arn:aws:iam::123456789012:role/test-dev-ecs-task-execution"
  ecs_task_role_arn           = "arn:aws:iam::123456789012:role/test-dev-ecs-task"
  db_endpoint                 = "test-dev-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com"
  db_username                 = "platform_app"
  # log_retention_days uses module default: 7
}

# ── ALB: must be internet-facing ──────────────────────────────────────────────
#
# ECS tasks are in public subnets (no NAT Gateway) so the ALB must be external.
# An internal ALB would make the service unreachable from outside the VPC.

run "alb_is_internet_facing" {
  command = plan

  assert {
    condition     = aws_lb.app.internal == false
    error_message = "ALB must be internet-facing (internal=false). An internal ALB would make the service unreachable from outside the VPC."
  }
}

# ── ECS service: tasks must receive public IPs ────────────────────────────────
#
# Tasks run in public subnets and reach ECR / Secrets Manager / CloudWatch via
# the IGW.  Without assign_public_ip=true tasks would have no route to pull
# their image or write logs.

run "ecs_service_assigns_public_ip" {
  command = plan

  assert {
    condition     = one(aws_ecs_service.app.network_configuration).assign_public_ip == true
    error_message = "ECS tasks must have assign_public_ip=true. Without a NAT Gateway, tasks need a public IP to reach ECR, Secrets Manager, and CloudWatch via the IGW."
  }
}

# ── CloudWatch log group: retention must honour the input variable ────────────
#
# Verifying that log_retention_days is actually wired to the log group guards
# against accidentally hardcoding a value that differs from the variable.

run "log_group_retention_matches_variable" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == var.log_retention_days
    error_message = "CloudWatch log group retention_in_days must equal var.log_retention_days. Check that the variable is wired correctly in the resource."
  }
}

# ── ALB target group: health check must probe /healthz ───────────────────────
#
# /healthz is the liveness probe — it returns 200 without hitting the database.
# /readyz is intentionally excluded from the ALB health check: an unhealthy DB
# connection would deregister all tasks simultaneously, causing an outage.

run "alb_health_check_probes_healthz" {
  command = plan

  assert {
    condition     = one(aws_lb_target_group.app.health_check).path == "/healthz"
    error_message = "ALB target group health check must use /healthz (liveness probe). /readyz is excluded to avoid deregistering all tasks on a transient DB blip."
  }

  assert {
    condition     = one(aws_lb_target_group.app.health_check).matcher == "200"
    error_message = "ALB health check matcher must be '200'. Any other status code would keep tasks out of rotation even when the app is healthy."
  }
}

# ── ECR: image tags must be immutable ─────────────────────────────────────────
#
# IMMUTABLE tags ensure that a commit-SHA tag always refers to exactly the image
# that was built for that commit.  Without this, a second push could overwrite
# the tag, making rollbacks unreliable.

run "ecr_immutable_tags" {
  command = plan

  assert {
    condition     = aws_ecr_repository.app.image_tag_mutability == "IMMUTABLE"
    error_message = "ECR repository must use IMMUTABLE tag mutability. Mutable tags allow an image to be overwritten, undermining commit-SHA-based rollbacks."
  }
}

# ── Container: health check must allow enough startup time ───────────────────
#
# The startPeriod of 60 s gives the container time to start uvicorn and run
# Alembic migrations before ECS begins counting health-check failures.  A
# shorter startPeriod would cause false failures on a cold start.

run "container_health_check_start_period" {
  command = apply

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  # The mock provider returns random strings for computed ARNs.  The ALB listener
  # and ECS service validate that load_balancer_arn / target_group_arn are valid
  # ARN strings, so we override with fake-but-valid ARN values to unblock apply.
  override_resource {
    target = aws_lb.app
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/test-dev/1234567890abcdef"
    }
  }

  override_resource {
    target = aws_lb_target_group.app
    values = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test-dev/1234567890abcdef"
    }
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.app.container_definitions)[0].healthCheck.startPeriod == 60
    error_message = "Container health check startPeriod must be 60 s. A shorter value causes false failures during cold start while Alembic migrations are running."
  }

  assert {
    condition = anytrue([
      for cmd in jsondecode(aws_ecs_task_definition.app.container_definitions)[0].healthCheck.command :
      strcontains(cmd, "/healthz")
    ])
    error_message = "Container health check command must probe /healthz."
  }
}
