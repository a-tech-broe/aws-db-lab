output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key."
  value       = aws_kms_key.this.arn
}

output "kms_key_id" {
  description = "Key ID of the customer-managed KMS key."
  value       = aws_kms_key.this.key_id
}

output "kms_alias" {
  description = "Alias of the customer-managed KMS key."
  value       = aws_kms_alias.this.name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master credentials."
  value       = aws_secretsmanager_secret.db_master.arn
}

output "db_secret_name" {
  description = "Name of the Secrets Manager secret holding the master credentials."
  value       = aws_secretsmanager_secret.db_master.name
}

output "db_master_username" {
  description = "Master username."
  value       = var.db_master_username
}

output "db_master_password" {
  description = "Generated master password. Consumed by the RDS module; never printed."
  value       = random_password.db_master.result
  sensitive   = true
}

output "app_security_group_id" {
  description = "Security group ID for the application tier."
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "Security group ID for the database tier."
  value       = aws_security_group.db.id
}
