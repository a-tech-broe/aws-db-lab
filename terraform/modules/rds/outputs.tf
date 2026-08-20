output "db_instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "db_instance_arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.this.arn
}

output "db_instance_address" {
  description = "DNS address of the instance (writer endpoint)."
  value       = aws_db_instance.this.address
}

output "db_instance_endpoint" {
  description = "host:port of the instance."
  value       = aws_db_instance.this.endpoint
}

output "db_instance_port" {
  description = "Listener port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "db_instance_availability_zone" {
  description = "AZ currently hosting the primary. Flips on failover (Phase 4)."
  value       = aws_db_instance.this.availability_zone
}

output "db_instance_resource_id" {
  description = "Immutable resource ID (dbi-...), used for IAM auth policies and Performance Insights."
  value       = aws_db_instance.this.resource_id
}

output "db_instance_status" {
  description = "Instance status at apply time."
  value       = aws_db_instance.this.status
}

output "parameter_group_name" {
  description = "Custom parameter group applied to the instance."
  value       = aws_db_parameter_group.this.name
}

output "monitoring_role_arn" {
  description = "Enhanced Monitoring IAM role ARN, if enabled."
  value       = try(aws_iam_role.monitoring[0].arn, null)
}

output "log_group_names" {
  description = "CloudWatch log groups receiving exported PostgreSQL logs."
  value       = [for lg in aws_cloudwatch_log_group.exports : lg.name]
}
