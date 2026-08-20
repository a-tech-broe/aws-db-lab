variable "aws_region" {
  description = "Primary region. us-west-2 joins as the DR region in the cross-region phase."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used to build every resource name."
  type        = string
  default     = "awsdblab"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag, so lab resources are attributable in the bill."
  type        = string
  default     = "sre-lab"
}

# ------------------------------ Networking ---------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs. 3 gives Multi-AZ room to fail over twice."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway. Set false for one per AZ in a production posture."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch."
  type        = bool
  default     = true
}

# ------------------------------- Database ----------------------------------

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "db_parameter_group_family" {
  description = "Parameter group family matching db_engine_version."
  type        = string
  default     = "postgres16"
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "Master username."
  type        = string
  default     = "dbadmin"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 200
}

variable "db_multi_az" {
  description = "Multi-AZ. Required by the failover lab; set false only to cut cost while iterating."
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Automated backup retention in days -- also the PITR window."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Deletion protection on the instance."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy."
  type        = bool
  default     = false
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications immediately instead of in the maintenance window."
  type        = bool
  default     = true
}

variable "db_max_connections" {
  description = <<-EOT
    Expected max_connections, used to scale the connection alarm. RDS derives
    it as LEAST({DBInstanceClassMemory/9531392}, 5000): ~450 on db.t4g.medium
    (4 GiB), ~900 on db.t4g.large (8 GiB). Update alongside db_instance_class.
  EOT
  type        = number
  default     = 450
}

variable "db_instance_memory_bytes" {
  description = "Physical memory of db_instance_class, used to scale the memory alarm."
  type        = number
  default     = 4294967296 # 4 GiB, db.t4g.medium
}

# ----------------------------- Observability -------------------------------

variable "alarm_email" {
  description = "Address subscribed to the alarm topic. Null creates the topic with no subscription."
  type        = string
  default     = null
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds."
  type        = number
  default     = 30
}

# ------------------------------- Optional ----------------------------------

variable "enable_bastion" {
  description = <<-EOT
    Create the SSM-only maintenance host in the private app subnet. Needed to
    run psql against the private database before the application exists.
  EOT
  type        = bool
  default     = false
}
