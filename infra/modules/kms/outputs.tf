output "kms_key_arn" {
  description = "ARN of the platform CMK. Pass to the data module (Aurora + Secrets Manager) and to the IAM module for scoping KMS permissions."
  value       = aws_kms_key.platform.arn
}

output "kms_key_id" {
  description = "Key ID of the platform CMK (short form, e.g. 'mrk-...'). Used as the alias target."
  value       = aws_kms_key.platform.key_id
}

output "kms_alias_arn" {
  description = "ARN of the key alias (alias/{project_name}-{environment}). Use for human-readable references in policies."
  value       = aws_kms_alias.platform.arn
}
