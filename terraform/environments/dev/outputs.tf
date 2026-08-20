# Outputs are the contract every later phase builds against. Adding is fine;
# renaming breaks the scripts in scripts/ and the workflows in .github/.

output "region" {
  description = "Region this environment is deployed in."
  value       = var.aws_region
}

output "name_prefix" {
  description = "Prefix shared by every resource name."
  value       = local.name_prefix
}

# ------------------------------ Networking ---------------------------------

output "vpc_id" {
  description = "VPC ID."
  value       = module.networking.vpc_id
}

output "availability_zones" {
  description = "AZs in use."
  value       = module.networking.availability_zones
}

output "public_subnet_ids" {
  description = "Public subnets (ALB in Phase 2)."
  value       = module.networking.public_subnet_ids
}

output "private_app_subnet_ids" {
  description = "Private application subnets (ECS Fargate in Phase 2)."
  value       = module.networking.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Private database subnets."
  value       = module.networking.private_db_subnet_ids
}

output "db_subnet_group_name" {
  description = "RDS DB subnet group."
  value       = module.networking.db_subnet_group_name
}

# ------------------------------- Security ----------------------------------

output "kms_key_arn" {
  description = "Customer-managed KMS key ARN."
  value       = module.security.kms_key_arn
}

output "kms_key_alias" {
  description = "Customer-managed KMS key alias."
  value       = module.security.kms_alias
}

output "app_security_group_id" {
  description = "Application tier security group -- attach Fargate tasks to this."
  value       = module.security.app_security_group_id
}

output "db_security_group_id" {
  description = "Database tier security group."
  value       = module.security.db_security_group_id
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the master credentials and endpoint."
  value       = module.security.db_secret_arn
}

output "db_secret_name" {
  description = "Name of the credentials secret."
  value       = module.security.db_secret_name
}

# ------------------------------- Database ----------------------------------

output "db_instance_id" {
  description = "RDS instance identifier."
  value       = module.rds.db_instance_id
}

output "db_instance_arn" {
  description = "RDS instance ARN."
  value       = module.rds.db_instance_arn
}

output "db_instance_address" {
  description = "Writer endpoint hostname."
  value       = module.rds.db_instance_address
}

output "db_instance_endpoint" {
  description = "host:port."
  value       = module.rds.db_instance_endpoint
}

output "db_instance_port" {
  description = "Listener port."
  value       = module.rds.db_instance_port
}

output "db_name" {
  description = "Initial database name."
  value       = module.rds.db_name
}

output "db_instance_availability_zone" {
  description = "AZ currently hosting the primary."
  value       = module.rds.db_instance_availability_zone
}

output "db_instance_resource_id" {
  description = "Immutable dbi-* resource ID."
  value       = module.rds.db_instance_resource_id
}

output "db_parameter_group_name" {
  description = "Custom parameter group in use."
  value       = module.rds.parameter_group_name
}

output "db_log_group_names" {
  description = "CloudWatch log groups receiving PostgreSQL logs."
  value       = module.rds.log_group_names
}

# ----------------------------- Observability -------------------------------

output "alarm_topic_arn" {
  description = "SNS topic every database alarm publishes to."
  value       = module.monitoring.sns_topic_arn
}

output "alarm_names" {
  description = "CloudWatch alarms guarding the database."
  value       = module.monitoring.alarm_names
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = module.monitoring.dashboard_name
}

output "dashboard_url" {
  description = "Direct link to the CloudWatch dashboard."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.monitoring.dashboard_name}"
}

# ------------------------------- Optional ----------------------------------

output "bastion_instance_id" {
  description = "Maintenance host instance ID, if enabled."
  value       = try(module.bastion[0].instance_id, null)
}

output "psql_command" {
  description = "How to connect once you are inside the VPC. TLS is enforced by rds.force_ssl."
  value = join(" ", [
    "psql",
    "\"host=${module.rds.db_instance_address}",
    "port=${module.rds.db_instance_port}",
    "dbname=${module.rds.db_name}",
    "user=${module.security.db_master_username}",
    "sslmode=require\"",
  ])
}
