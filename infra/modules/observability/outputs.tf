output "alerts_topic_arn" {
  description = "ARN of the operational alerts SNS topic. Subscribe additional endpoints (PagerDuty, Slack, etc.) with aws_sns_topic_subscription resources in the calling env."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard (used to build the console URL in envs/dev/outputs.tf). Added in Stage 3."
  value       = "CVSPlatformDev"
}
