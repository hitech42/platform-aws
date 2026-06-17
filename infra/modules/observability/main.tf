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
