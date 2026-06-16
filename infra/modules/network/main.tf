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

# Use the first 2 available AZs in the region — avoids hardcoding "us-east-1a" etc.
data "aws_availability_zones" "available" {
  state = "available"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # Required for RDS endpoint resolution.

  tags = merge(local.tags, { Name = "${local.prefix}-vpc" })
}

# ── Subnets ───────────────────────────────────────────────────────────────────
#
# 4-subnet layout (2 public + 2 private across 2 AZs):
#
#   Public  (AZ-0, AZ-1): ALB + ECS tasks.  Tasks get public IPs and route
#     outbound traffic to ECR/Secrets Manager/CloudWatch via the IGW.
#     No NAT Gateway — saves ~$32/mo per AZ for a dev environment.
#
#   Private (AZ-0, AZ-1): RDS DB subnet group.  No route to the internet
#     (no NAT), so RDS cannot initiate outbound connections.  This provides
#     a second network-isolation layer beyond the security group: even a
#     misconfigured db_sg cannot be exploited from the internet because there
#     is no path from private subnets to the IGW.
#
# For staging/prod: add NAT Gateways (one per AZ for HA) and move ECS tasks
# to the private subnets so they are not reachable from the internet even with
# a misconfigured ecs_service_sg.

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # ECS tasks need public IPs to reach AWS APIs via IGW.

  tags = merge(local.tags, {
    Name = "${local.prefix}-public-${count.index}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${local.prefix}-private-${count.index}"
    Tier = "private"
  })
}

# ── Internet Gateway + routing ────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${local.prefix}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${local.prefix}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table: local VPC routing only (no default route, no NAT).
# RDS only needs to be reachable FROM ECS tasks (intra-VPC), not to reach
# the internet itself.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, { Name = "${local.prefix}-rt-private" })
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security groups ───────────────────────────────────────────────────────────

# ALB — accepts HTTP (port 80) from the internet.
#
# HTTPS/443 is NOT enabled for this dev environment: it requires an ACM cert
# and a registered domain, which are out of scope.  Document this as a known
# simplification; staging/prod must use HTTPS.
resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb-sg"
  description = "ALB: HTTP from internet (HTTPS omitted for dev - see comment)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound to ECS tasks (and anything else — ALB needs to reach health-check
  # endpoints, which may vary by port).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefix}-alb-sg" })
}

# ECS service — inbound ONLY from the ALB, outbound to internet (ECR, Secrets
# Manager, CloudWatch Logs, RDS).
#
# Why outbound-all from a public-subnet ECS task works without NAT:
#   ECS tasks in public subnets get a public IP (map_public_ip_on_launch=true).
#   The public route table has a default route to the IGW.
#   So outbound packets from the task → IGW → internet, just like an EC2 in
#   a public subnet.  No NAT Gateway needed.
resource "aws_security_group" "ecs_service" {
  name        = "${local.prefix}-ecs-service-sg"
  description = "ECS tasks: inbound app port from ALB only; outbound all (ECR/SM/CW via IGW)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from ALB only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefix}-ecs-service-sg" })
}

# RDS DB — inbound Postgres ONLY from ECS tasks, outbound all.
#
# Outbound is left as allow-all rather than none because:
#  - RDS needs to communicate with Route 53 (DNS) for its own endpoint resolution.
#  - The private subnets have no route to the internet anyway (no NAT, no IGW
#    default route), so "allow-all outbound" in a security group attached to a
#    private-subnet resource does not grant actual internet access — the routing
#    table is the real barrier.
#  - This avoids edge cases with the AWS provider's default-egress behavior.
resource "aws_security_group" "db" {
  name        = "${local.prefix}-db-sg"
  description = "RDS: inbound Postgres from ECS service only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from ECS tasks only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_service.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.prefix}-db-sg" })
}
