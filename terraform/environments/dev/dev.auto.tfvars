# Committed, non-secret settings for the dev environment.
#
# alarm_email is deliberately NOT here -- it is a personal address. Locally it
# comes from terraform.tfvars (gitignored); in CI from the TF_VAR_alarm_email
# repository secret. Terraform reads TF_VAR_* at lowest precedence, so nothing
# in this file shadows it.

aws_region  = "us-east-1"
project     = "awsdblab"
environment = "dev"
owner       = "jenom"

# --- Networking ---
vpc_cidr           = "10.20.0.0/16"
az_count           = 3
single_nat_gateway = true
enable_flow_logs   = true

# --- Database ---
db_instance_class          = "db.t4g.medium"
db_allocated_storage       = 50
db_max_allocated_storage   = 200
db_multi_az                = true
db_backup_retention_period = 7
db_deletion_protection     = true
db_apply_immediately       = true

# Keep consistent with db_instance_class -- these scale the alarm thresholds.
db_max_connections       = 450        # db.t4g.medium
db_instance_memory_bytes = 4294967296 # 4 GiB

# --- Optional ---
enable_bastion = true
