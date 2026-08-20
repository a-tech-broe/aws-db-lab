# ---------------------------------------------------------------------------
# aws-db-lab / dev -- Phase 1: production PostgreSQL foundation.
#
#   networking  VPC, 3 AZs, public + private-app + private-db subnets, NAT,
#               DB subnet group, flow logs
#   security    KMS CMK, Secrets Manager master credential, app and db
#               security groups with a single ingress path
#   rds         Multi-AZ PostgreSQL, encrypted, custom parameter group,
#               automated backups, Enhanced Monitoring, Performance Insights
#   monitoring  SNS topic, CloudWatch alarms, dashboard
#   bastion     optional SSM-only maintenance host
#
# Every later phase attaches to these outputs rather than replacing them.
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    Phase       = "1-foundation"
    Repository  = "aws-db-lab"
  }
}

module "networking" {
  source = "../../modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  enable_flow_logs   = var.enable_flow_logs
  kms_key_arn        = module.security.kms_key_arn

  tags = local.common_tags
}

module "security" {
  source = "../../modules/security"

  name_prefix        = local.name_prefix
  vpc_id             = module.networking.vpc_id
  db_master_username = var.db_master_username

  tags = local.common_tags
}

module "rds" {
  source = "../../modules/rds"

  name_prefix            = local.name_prefix
  db_subnet_group_name   = module.networking.db_subnet_group_name
  vpc_security_group_ids = [module.security.db_security_group_id]
  kms_key_arn            = module.security.kms_key_arn

  engine_version         = var.db_engine_version
  parameter_group_family = var.db_parameter_group_family
  instance_class         = var.db_instance_class
  db_name                = var.db_name
  master_username        = module.security.db_master_username
  master_password        = module.security.db_master_password
  secret_arn             = module.security.db_secret_arn

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage

  multi_az                = var.db_multi_az
  deletion_protection     = var.db_deletion_protection
  skip_final_snapshot     = var.db_skip_final_snapshot
  apply_immediately       = var.db_apply_immediately
  backup_retention_period = var.db_backup_retention_period
  monitoring_interval     = var.monitoring_interval

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix    = local.name_prefix
  db_instance_id = module.rds.db_instance_id
  kms_key_arn    = module.security.kms_key_arn
  alarm_email    = var.alarm_email

  # Alarm thresholds are percentages of these, so they stay correct when the
  # instance class changes.
  instance_memory_bytes   = var.db_instance_memory_bytes
  allocated_storage_bytes = var.db_allocated_storage * 1024 * 1024 * 1024
  max_connections         = var.db_max_connections
  is_burstable_instance   = can(regex("^db\\.t[34]g?\\.", var.db_instance_class))

  tags = local.common_tags
}

module "bastion" {
  source = "../../modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  name_prefix          = local.name_prefix
  vpc_id               = module.networking.vpc_id
  subnet_id            = module.networking.private_app_subnet_ids[0]
  db_security_group_id = module.security.db_security_group_id
  db_secret_arn        = module.security.db_secret_arn
  kms_key_arn          = module.security.kms_key_arn

  tags = local.common_tags
}
