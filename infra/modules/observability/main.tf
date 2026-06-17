locals {
  prefix = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── SNS topic: operational / service alerts ───────────────────────────────────
#
# Kept separate from the billing alarm topic (created in envs/dev/main.tf) so
# that ops/on-call subscribers and billing-watchers can manage their own
# subscriptions independently, and a billing alert doesn't wake the on-call
# engineer at 3 AM (see DECISIONS.md ADR-0XX).

resource "aws_sns_topic" "alerts" {
  name = "${local.prefix}-alerts"
  tags = local.tags
}

# Email subscription — requires manual confirmation before alerts fire.
#
# IMPORTANT: after `terraform apply`, AWS sends a confirmation email to
# var.alert_email.  The subscription status is PENDING_CONFIRMATION until the
# recipient clicks the confirmation link.  Alarms that fire before confirmation
# are silently dropped.  Confirm the subscription immediately after apply.
#
# To check subscription status:
#   aws sns list-subscriptions-by-topic \
#     --topic-arn <alerts_topic_arn>

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── ECS alarms ────────────────────────────────────────────────────────────────
#
# Memory metrics (MemoryUtilized/MemoryReserved) are only available in the
# ECS/ContainerInsights namespace when container insights is enabled on the
# cluster (infra/modules/ecs-service/main.tf). The standard AWS/ECS namespace
# publishes CPU but not memory for Fargate tasks.

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name        = "${local.prefix}-ecs-cpu-high"
  alarm_description = "ECS CPU utilization above 80% for 10 minutes. Action: check for traffic spike or runaway process; consider scaling desired_count or increasing task CPU."

  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = var.ecs_service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name        = "${local.prefix}-ecs-memory-high"
  alarm_description = "ECS memory utilization above 80% for 10 minutes. Action: check for memory leak or increase task_memory in the ecs-service module variables."

  # Container Insights namespace — requires containerInsights=enabled on the cluster.
  namespace           = "ECS/ContainerInsights"
  metric_name         = "MemoryUtilized"
  dimensions          = { ClusterName = var.ecs_cluster_name, ServiceName = var.ecs_service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# ── RDS alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name        = "${local.prefix}-rds-cpu-high"
  alarm_description = "RDS CPU utilization above 80% for 10 minutes. Action: investigate slow queries (pg_stat_statements), check for missing indexes, or upgrade instance class."

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name        = "${local.prefix}-rds-storage-low"
  alarm_description = "RDS free storage below 2 GB. Action: expand allocated_storage in the data module immediately — at 0 bytes free, the instance becomes read-only and the service stops accepting writes."

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  dimensions  = { DBInstanceIdentifier = var.rds_instance_identifier }
  statistic   = "Average"
  # 1 datapoint — low storage is a hard stop, alert on first breach not after two periods.
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB in bytes
  comparison_operator = "LessThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name        = "${local.prefix}-rds-connections-high"
  alarm_description = "RDS connection count above 20 for 10 minutes. At dev scale this should never fire; it is a canary for connection-pool leaks. Action: check for unclosed sessions in pg_stat_activity and review SQLAlchemy pool settings."

  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = var.rds_instance_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# ── ALB alarms ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name        = "${local.prefix}-alb-5xx-high"
  alarm_description = "ALB recorded more than 10 target 5xx errors in a 5-minute window. Action: check ECS task logs in CloudWatch for unhandled exceptions; correlate with deployment or DB connectivity events."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  dimensions  = { LoadBalancer = var.alb_arn_suffix }
  # Sum not Average — we care about the absolute error count at this scale,
  # not the error rate per request. 10 errors in 5 min is actionable regardless
  # of traffic volume in a dev environment.
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  # treat_missing_data=notBreaching: no traffic == no errors, not an alarm state.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p95" {
  alarm_name        = "${local.prefix}-alb-latency-p95-high"
  alarm_description = "ALB p95 target response time above 2 seconds for 10 minutes. p95 is the latency SLI: it reflects the worst experience real users have while ignoring the occasional outlier. Action: check for slow DB queries, lock contention, or under-provisioned tasks."

  namespace   = "AWS/ApplicationELB"
  metric_name = "TargetResponseTime"
  dimensions  = { LoadBalancer = var.alb_arn_suffix }
  # extended_statistic instead of statistic for percentile expressions.
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2.0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_healthy_hosts" {
  alarm_name        = "${local.prefix}-alb-no-healthy-hosts"
  alarm_description = "ALB has zero healthy targets — the service is completely unavailable. Action: immediately check ECS service events and task health in the console; review recent deployments."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  dimensions  = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.tg_arn_suffix }
  statistic   = "Minimum"
  # 60-second period catches a complete outage 5x faster than the standard 300s window.
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# ── Application-level: CloudWatch Logs metric filter + alarm ─────────────────
#
# Full chain realized from session 4's Stage 2 design intent:
#   structlog event in app code (secret_requests.py)
#   → awslogs driver forwards to CloudWatch Logs (/ecs/cvs-platform-dev)
#   → metric filter extracts matching log lines and increments the counter
#   → CloudWatch alarm evaluates the counter
#   → alarm fires to SNS topic
#   → email delivered to var.alert_email
#
# The app code emits:
#   log.warning("secret_provisioning_outcome", outcome="failed", ...)
# structlog renders this as JSON with {"event": "secret_provisioning_outcome",
# "outcome": "failed", ...}, which the filter below matches.

resource "aws_cloudwatch_log_metric_filter" "secret_provisioning_failures" {
  name           = "${local.prefix}-secret-provisioning-failures"
  log_group_name = var.log_group_name

  # JSON filter syntax: field names prefixed with $. — must match structlog's
  # JSON output keys exactly. The event key is structlog's positional arg;
  # outcome is the keyword arg passed to log.warning().
  pattern = "{ $.event = \"secret_provisioning_outcome\" && $.outcome = \"failed\" }"

  metric_transformation {
    namespace = "CVSPlatform/Application"
    name      = "SecretProvisioningFailures"
    value     = "1" # each matching log line = 1 failure event
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "secret_provisioning_failures" {
  alarm_name        = "${local.prefix}-secret-provisioning-failures"
  alarm_description = "A secret provisioning request failed. This directly impacts a developer trying to self-serve. Action: check CloudWatch Logs for the failed request_id and the underlying Secrets Manager error (ResourceExistsException = duplicate name; ClientError = AWS permission gap or quota)."

  namespace   = "CVSPlatform/Application"
  metric_name = "SecretProvisioningFailures"
  # No dimensions — this is a custom metric with no dimension (matches all data points).
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 1
  # Threshold of 1: zero tolerance — any provisioning failure should alert immediately.
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # notBreaching: periods with no provisioning attempts (metric not reported)
  # are healthy, not alarming.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}
