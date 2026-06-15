output "cluster_endpoint" {
  description = "Writer endpoint for the Aurora cluster. Use in DATABASE_URL for read-write connections."
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Reader endpoint for the Aurora cluster. Routes to read-only replica instances when available; falls back to writer in single-instance dev."
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_resource_id" {
  description = "Cluster resource identifier (e.g. 'cluster-ABCDEFGHIJK'). Required to construct the rds-db:connect IAM permission ARN for IAM database authentication."
  value       = aws_rds_cluster.aurora.cluster_resource_id
}

output "port" {
  description = "Database port (5432 for Aurora PostgreSQL)."
  value       = aws_rds_cluster.aurora.port
}

output "database_name" {
  description = "Name of the default database in the Aurora cluster."
  value       = aws_rds_cluster.aurora.database_name
}

output "db_username" {
  description = "IAM-auth application DB username. Used in DATABASE_URL construction alongside an IAM-generated auth token (no password)."
  value       = var.db_username
}

output "master_secret_arn" {
  description = "ARN of the Aurora-managed master credential secret in Secrets Manager. For break-glass / administrative access only — the app never uses this credential."
  value       = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
}
