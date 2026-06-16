output "ecr_repository_url" {
  description = "ECR repository URL (without tag). Used by CI/CD to push images: append :<commit-sha> for the immutable production tag."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository. Used to scope ECR pull permissions on the task execution role."
  value       = aws_ecr_repository.app.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster. Used by CI/CD to update the service and wait for stability."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service. Used by CI/CD to trigger rolling deploys."
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "ECS task definition family name. CI/CD describes the current revision, substitutes the image, and registers the next revision."
  value       = aws_ecs_task_definition.app.family
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. This is the service's base URL: http://{alb_dns_name}/api/v1/..."
  value       = aws_lb.app.dns_name
}

output "log_group_name" {
  description = "CloudWatch log group name for the ECS tasks. Used to scope logs:CreateLogStream + logs:PutLogEvents on the task execution role."
  value       = aws_cloudwatch_log_group.app.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch log group. Used to scope IAM permissions precisely."
  value       = aws_cloudwatch_log_group.app.arn
}
