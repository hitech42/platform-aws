terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── ECR Repository ────────────────────────────────────────────────────────────
#
# IMMUTABLE tags are intentional: every image is pushed with a git commit SHA
# tag (e.g. "abc1234").  Immutability prevents accidental overwrites and makes
# rollbacks unambiguous — to roll back, update the ECS service to the previous
# SHA tag; the image is guaranteed to still be exactly what was built then.
# "latest" is never used in production task definitions for this reason.

resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Free scan on every push — catches known CVEs automatically without any
    # additional tooling.  Results are visible in the ECR console and can drive
    # CloudWatch alarms in E4.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    # Consistent encryption story: ECR images, RDS storage, Secrets Manager
    # secrets, and CloudWatch logs all use the same platform CMK.
    kms_key = var.kms_key_arn
  }

  tags = merge(local.tags, { Name = var.project_name })
}

# ── ECR Lifecycle Policy ──────────────────────────────────────────────────────
#
# Retain only the last 10 tagged images.  Active dev pushes can accumulate
# dozens of images per day; without a lifecycle policy, ECR storage costs grow
# unbounded (free-tier storage has a 500 MiB limit per month).
# Untagged images (intermediate build layers) are expired after 1 day.

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.ecr_image_count_limit} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = [""]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_image_count_limit
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────
#
# Created here alongside the task definition so the log group exists before
# the ECS service starts and tries to write to it.  ECS does not create the
# log group automatically when using the awslogs driver.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(local.tags, { Name = "/ecs/${local.prefix}" })
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
#
# Container Insights is DISABLED for dev: it sends ~10 custom CloudWatch metrics
# per task per minute, billed at $0.30/metric/month ≈ $3+/month extra — not
# free-tier.  E4 will add targeted CloudWatch alarms on the standard ECS metrics
# (which are free) instead.  Enable for staging/prod where the observability
# trade-off is worth the cost.

resource "aws_ecs_cluster" "main" {
  name = local.prefix

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = merge(local.tags, { Name = local.prefix })
}

# ── ECS Task Definition ───────────────────────────────────────────────────────
#
# Terraform manages the task definition infrastructure (roles, log config,
# environment variables, resource limits).  The CI/CD pipeline (app-deploy.yml)
# manages the IMAGE VERSION by registering a new task definition revision with
# the commit-SHA-tagged image on each deploy — Terraform state is not updated
# on each code push, avoiding state drift.
#
# container_image defaults to "placeholder" for the initial apply (before any
# image has been pushed to ECR).  The first real deploy via CI/CD overwrites
# this with the actual ECR URI + commit SHA tag.

resource "aws_ecs_task_definition" "app" {
  family                   = local.prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Minimum Fargate size (256 CPU = 0.25 vCPU, 512 MiB).  Cost-conscious for
  # dev; size up based on load testing results for staging/prod.
  cpu    = var.task_cpu
  memory = var.task_memory

  execution_role_arn = var.ecs_task_execution_role_arn
  task_role_arn      = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name  = var.project_name
      image = var.container_image

      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AWS_DEFAULT_REGION", value = data.aws_region.current.name },
        { name = "DB_AUTH_MODE", value = "iam" },
        {
          name = "DATABASE_URL"
          # No password in the connection string — the app generates an IAM
          # auth token at runtime using rds-db:connect and injects it as the
          # password when opening the connection.
          value = "postgresql://${var.db_username}@${var.db_endpoint}:5432/${var.db_name}"
        },
        { name = "LOG_LEVEL", value = "INFO" },
        # AWS_ENDPOINT_URL is intentionally omitted: this is a real AWS
        # environment, not LocalStack.  The app's boto3 clients use the default
        # AWS service endpoints.
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        # startPeriod gives the app time to complete startup and Alembic
        # migrations before health checks begin counting failures.
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.app_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      essential = true
    }
  ])

  tags = merge(local.tags, { Name = local.prefix })
}

data "aws_region" "current" {}

# ── Application Load Balancer ─────────────────────────────────────────────────
#
# HTTP-only (port 80) for dev — no HTTPS/ACM cert required.  This is a known
# simplification documented in DECISIONS.md.  The prod path is:
#   ACM cert + Route 53 alias → HTTPS listener + HTTP-to-HTTPS redirect rule.

resource "aws_lb" "app" {
  name               = local.prefix
  internal           = false # internet-facing — this is the public entry point
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [var.alb_sg_id]

  tags = merge(local.tags, { Name = local.prefix })
}

# ── ALB Target Group ──────────────────────────────────────────────────────────

resource "aws_lb_target_group" "app" {
  name        = local.prefix
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "ip" # required for Fargate awsvpc network mode
  vpc_id      = var.vpc_id

  health_check {
    path                = "/healthz"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = local.prefix })
}

# ── ALB Listener ──────────────────────────────────────────────────────────────

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = merge(local.tags, { Name = "${local.prefix}-http" })
}

# ── ECS Service ───────────────────────────────────────────────────────────────
#
# Tasks run in PUBLIC subnets with assign_public_ip=ENABLED.  This avoids a
# NAT Gateway (~$32/mo per AZ) by letting tasks reach ECR, Secrets Manager,
# CloudWatch, and RDS over the internet/AWS backbone via the IGW directly.
# The ecs_service_sg restricts inbound to ALB only; outbound is open.
# See DECISIONS.md (ADR-013) for the full trade-off analysis.
#
# wait_for_steady_state=false: Terraform does not block on deployment
# completion.  The CI/CD pipeline (app-deploy.yml) handles deployment
# verification via `aws ecs wait services-stable` and a /healthz smoke test.

resource "aws_ecs_service" "app" {
  name            = local.prefix
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.ecs_service_sg_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = var.app_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  wait_for_steady_state = false

  tags = merge(local.tags, { Name = local.prefix })

  # The task definition ARN changes on every CI/CD deploy (new revision).
  # Ignore it here so Terraform doesn't show a perpetual diff after the first
  # deployment — the pipeline owns the image version, not Terraform.
  lifecycle {
    ignore_changes = [task_definition]
  }
}
