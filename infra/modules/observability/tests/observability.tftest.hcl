# Run from infra/modules/observability/:
#   terraform init -backend=false
#   terraform test
#
# All runs use mock_provider — no AWS credentials required.
#
# command=apply is used for the alarm_actions assertion: alarm_actions references
# aws_sns_topic.alerts.arn which is computed (unknown at plan time). apply with
# mock_provider resolves it to a mock string so length() is evaluable.
#
# command=plan is used for threshold, period, and topic-name assertions —
# all set directly in HCL, so values are known at plan time.
#
# override_data for aws_caller_identity and aws_region is required in every run
# because the module embeds account_id and region in the dashboard templatefile
# and in the alarm-status widget ARNs. Without overrides the mock provider
# returns random strings; with overrides the template renders deterministically.

mock_provider "aws" {}

variables {
  project_name            = "test"
  environment             = "dev"
  alert_email             = "test@example.com"
  ecs_cluster_name        = "test-dev"
  ecs_service_name        = "test-dev"
  alb_arn_suffix          = "app/test-dev/1234567890abcdef"
  tg_arn_suffix           = "test-dev/1234567890abcdef"
  rds_instance_identifier = "test-dev-postgres"
  log_group_name          = "/ecs/test-dev"
}

# ── All alarms must notify the alerts SNS topic ───────────────────────────────
#
# A silent alarm (alarm_actions = []) alerts nobody and is worse than no alarm:
# it gives false confidence that alerting is in place. Every alarm defined here
# must route to the operational alerts topic.

run "all_alarms_notify_sns" {
  command = apply

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  # override_resource is required: mock_provider generates a random non-ARN string
  # (e.g. "molko1rt") for aws_sns_topic.alerts.arn, which fails ARN validation in
  # alarm_actions, ok_actions, and topic_arn on dependent resources. Supplying a
  # valid fake ARN here unblocks those validations so the alarm assertions below
  # can evaluate. The assertion (length > 0) still catches the real failure mode
  # (alarm_actions = []) because the list itself is populated from this resource.
  override_resource {
    target = aws_sns_topic.alerts
    values = {
      arn  = "arn:aws:sns:us-east-1:123456789012:test-dev-alerts"
      name = "test-dev-alerts"
    }
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.ecs_cpu.alarm_actions) > 0
    error_message = "ecs_cpu alarm must have alarm_actions. A silent alarm provides no value — it signals nothing when CPU spikes."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.ecs_memory.alarm_actions) > 0
    error_message = "ecs_memory alarm must have alarm_actions."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_cpu.alarm_actions) > 0
    error_message = "rds_cpu alarm must have alarm_actions."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_storage.alarm_actions) > 0
    error_message = "rds_storage alarm must have alarm_actions. Low storage can make RDS read-only — this must always notify."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds_connections.alarm_actions) > 0
    error_message = "rds_connections alarm must have alarm_actions."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.alb_5xx.alarm_actions) > 0
    error_message = "alb_5xx alarm must have alarm_actions."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.alb_latency_p95.alarm_actions) > 0
    error_message = "alb_latency_p95 alarm must have alarm_actions."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.alb_healthy_hosts.alarm_actions) > 0
    error_message = "alb_healthy_hosts alarm must have alarm_actions. Zero healthy targets means total service outage — this must always notify."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.secret_provisioning_failures.alarm_actions) > 0
    error_message = "secret_provisioning_failures alarm must have alarm_actions. Every provisioning failure directly impacts a developer trying to self-serve."
  }
}

# ── HealthyHostCount must have a shorter period than all other alarms ─────────
#
# Zero healthy ALB targets means the service is completely unavailable.
# A 60-second period catches a total outage 5x faster than the standard 300s
# window used by all other alarms. This is an intentional design choice:
# catch the worst failure mode (complete outage) as fast as possible.

run "healthy_host_count_faster_period" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_healthy_hosts.period == 60
    error_message = "alb_healthy_hosts period must be 60 s. Zero healthy hosts = total outage; detect it 5x faster than the standard 5-minute window."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alb_healthy_hosts.period < aws_cloudwatch_metric_alarm.ecs_cpu.period
    error_message = "alb_healthy_hosts must have a shorter period than ecs_cpu (60s vs 300s). This documents the intentional asymmetry: outage detection is prioritised over noise reduction."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.ecs_cpu.period == 300
    error_message = "ecs_cpu period must be 300 s (standard 5-minute window). Short periods on non-critical metrics generate noise from transient spikes."
  }
}

# ── SecretProvisioningFailures alarm must have zero-tolerance threshold ────────
#
# Threshold of 1 means any single failure triggers the alarm immediately.
# A higher threshold (e.g. 5) would silently absorb failures before alerting,
# leaving developers without secrets and with no notification. >=1 is the
# minimum meaningful non-zero tolerance for a self-service system.

run "provisioning_failure_zero_tolerance" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.secret_provisioning_failures.threshold == 1
    error_message = "SecretProvisioningFailures threshold must be 1. Any higher value silently absorbs failures — each one represents a developer who could not provision their secret."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.secret_provisioning_failures.comparison_operator == "GreaterThanOrEqualToThreshold"
    error_message = "SecretProvisioningFailures must use GreaterThanOrEqualToThreshold so that exactly 1 failure triggers the alarm, not just values above 1."
  }
}

# ── Alerts SNS topic must be distinct from the billing alarm topic ────────────
#
# The operational alerts topic and the billing alarm topic serve different
# purposes: different subscribers (on-call eng vs finance), different urgency,
# different action. Naming is the enforcement mechanism here — the topic name
# must end with "-alerts" and must not contain "billing".

run "alerts_topic_distinct_from_billing" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "AIDAXXXXXXXXXXXXXXXXX"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      name        = "us-east-1"
      description = "US East (N. Virginia)"
    }
  }

  assert {
    condition     = endswith(aws_sns_topic.alerts.name, "-alerts")
    error_message = "Alerts SNS topic name must end with '-alerts'. This distinguishes it from the billing alarm topic and makes the purpose unambiguous."
  }

  assert {
    condition     = !strcontains(aws_sns_topic.alerts.name, "billing")
    error_message = "Alerts SNS topic must not contain 'billing' in its name. Operational and billing alerts use separate topics with separate subscriber lists."
  }
}
