output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform remote state. Copy this into infra/envs/*/backend.tf."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_lock_table_name" {
  description = "Name of the DynamoDB table for state locking. Copy this into infra/envs/*/backend.tf."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "state_bucket_arn" {
  description = "ARN of the state bucket — used in the GitHub Actions deploy role policy."
  value       = aws_s3_bucket.tfstate.arn
}

output "state_lock_table_arn" {
  description = "ARN of the lock table — used in the GitHub Actions deploy role policy."
  value       = aws_dynamodb_table.tfstate_lock.arn
}
