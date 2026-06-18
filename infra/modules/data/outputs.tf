output "db_instance_identifier" {
  description = "RDS DB instance identifier (e.g. 'cvs-platform-dev-postgres'). Used as the DBInstanceIdentifier CloudWatch metric dimension for AWS/RDS alarms."
  value       = aws_db_instance.postgres.identifier
}

output "db_arn" {
  description = "ARN of the RDS PostgreSQL instance. Used for IAM policy scoping."
  value       = aws_db_instance.postgres.arn
}

output "db_endpoint" {
  description = "Hostname of the RDS instance. Use in DATABASE_URL for read-write connections (combine with port output)."
  value       = aws_db_instance.postgres.address
}

output "db_resource_id" {
  description = "Instance resource identifier (e.g. 'db-ABCDEFGHIJK'). Required to construct the rds-db:connect IAM permission ARN for IAM database authentication."
  value       = aws_db_instance.postgres.resource_id
}

output "port" {
  description = "Database port (5432 for PostgreSQL)."
  value       = aws_db_instance.postgres.port
}

output "database_name" {
  description = "Name of the default database in the RDS instance."
  value       = aws_db_instance.postgres.db_name
}

output "db_username" {
  description = "IAM-auth application DB username. Used in DATABASE_URL construction alongside an IAM-generated auth token (no password)."
  value       = var.db_username
}

output "master_secret_arn" {
  description = "ARN of the RDS-managed master credential secret in Secrets Manager. For break-glass / administrative access only — the app never uses this credential."
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "deletion_protection" {
  description = "Whether deletion protection is enabled. false in dev (clean destroy), true in staging/prod (requires explicit flip before destroy)."
  value       = aws_db_instance.postgres.deletion_protection
}

output "skip_final_snapshot" {
  description = "Whether the final snapshot is skipped on destroy. true in dev (no data to preserve), false in staging/prod (retains recoverable backup)."
  value       = aws_db_instance.postgres.skip_final_snapshot
}
