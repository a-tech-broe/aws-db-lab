# ---------------------------------------------------------------------------
# RDS PostgreSQL: Multi-AZ instance, custom parameter group, Enhanced
# Monitoring role, Performance Insights, CloudWatch log export, and automated
# backups sized so Phase 5 has a real PITR window to restore into.
# ---------------------------------------------------------------------------

# --------------------------- Enhanced Monitoring ---------------------------
# Enhanced Monitoring reads OS-level metrics (per-process CPU, memory, disk)
# from inside the DB host -- the CloudWatch namespace alone cannot show these.

data "aws_iam_policy_document" "monitoring_assume" {
  count = var.monitoring_interval > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name               = "${var.name_prefix}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume[0].json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------- Parameter group ------------------------------

# name_prefix, not name: this group is create_before_destroy, so any forced
# replacement (a bad parameter, or bumping parameter_group_family for a major
# version upgrade) must be able to build the new group while the old one is
# still attached to the instance. A fixed name collides with itself and the
# apply fails with DBParameterGroupAlreadyExists.
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name_prefix}-pg-"
  family      = var.parameter_group_family
  description = "PostgreSQL tuning and observability parameters for ${var.name_prefix}"

  # pg_stat_statements is the backbone of Phase 7 (performance troubleshooting).
  # It is a shared library, so it needs a reboot -- hence "pending-reboot".
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # RDS enumerates this as NONE/TOP/ALL; match the casing exactly.
  parameter {
    name         = "pg_stat_statements.track"
    value        = "ALL"
    apply_method = "immediate"
  }

  # Log anything slow enough to be worth an EXPLAIN ANALYZE.
  parameter {
    name         = "log_min_duration_statement"
    value        = tostring(var.log_min_duration_statement_ms)
    apply_method = "immediate"
  }

  # Phase 7 lock/deadlock work depends on these three.
  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "deadlock_timeout"
    value        = "1000"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_autovacuum_min_duration"
    value        = "0"
    apply_method = "immediate"
  }

  # Connection churn is the signal Phase 6 measures.
  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  # RDS PostgreSQL accepts exactly two values for log_line_prefix:
  #   %t:%r:%u@%d:[%p]:                              (the default)
  #   %m:%r:%u@%d:[%p]:%l:%e:%s:%v:%x:%c:%q%a:       (verbose)
  # Anything else is rejected by ModifyDBParameterGroup. Take the verbose one:
  # beyond the default's timestamp/host/user/db/pid it adds millisecond
  # precision (%m), SQLSTATE (%e), transaction id (%x) and application_name
  # (%a) -- which is what makes a log line attributable during an incident.
  parameter {
    name         = "log_line_prefix"
    value        = "%m:%r:%u@%d:[%p]:%l:%e:%s:%v:%x:%c:%q%a:"
    apply_method = "immediate"
  }

  # Reject unencrypted connections outright. TLS is a Phase 9 control, but
  # there is no reason to start without it.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # A statement still running after 15 minutes in a lab is a runaway.
  # Phase 7 raises this deliberately to reproduce long-running queries.
  parameter {
    name         = "statement_timeout"
    value        = "900000"
    apply_method = "immediate"
  }

  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = "300000"
    apply_method = "immediate"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-parameter-group" })

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------- Instance ----------------------------------

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-postgres"

  engine                     = "postgres"
  engine_version             = var.engine_version
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  instance_class             = var.instance_class
  parameter_group_name       = aws_db_parameter_group.this.name

  db_name  = var.db_name
  port     = var.db_port
  username = var.master_username
  password = var.master_password

  # Networking: private subnets only, and publicly_accessible hard-off.
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = var.vpc_security_group_ids
  publicly_accessible    = false
  network_type           = "IPV4"

  # Storage: encrypted with the customer-managed key, autoscaling headroom.
  storage_type          = var.storage_type
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage == var.allocated_storage ? null : var.max_allocated_storage
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # Availability
  multi_az            = var.multi_az
  deletion_protection = var.deletion_protection
  apply_immediately   = var.apply_immediately

  # Backups
  backup_retention_period   = var.backup_retention_period
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = var.copy_tags_to_snapshot
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  delete_automated_backups  = false

  # Observability
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = var.performance_insights_retention_period
  enabled_cloudwatch_logs_exports       = var.enabled_cloudwatch_logs_exports

  # IAM database authentication -- Phase 9 uses it to drop password auth for
  # the application role entirely.
  iam_database_authentication_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgres" })

  # RDS auto-creates the exported log groups with "never expire" retention.
  # Creating them first means Terraform owns retention and encryption.
  depends_on = [aws_cloudwatch_log_group.exports]

  lifecycle {
    ignore_changes = [
      # AWS resolves "16" to a concrete minor and may bump it during the
      # maintenance window; do not fight it on every plan.
      engine_version,
      # The timestamp() above would otherwise churn on every plan.
      final_snapshot_identifier,
      # Phase 9 rotates the master password out of band.
      password,
    ]
  }
}

# Terraform does not create the exported log groups, RDS does -- so retention
# defaults to "never expire" unless we adopt them. These are imported on the
# second apply; the first apply creates them ahead of RDS.
resource "aws_cloudwatch_log_group" "exports" {
  for_each = toset(var.enabled_cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${var.name_prefix}-postgres/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

# ------------------- Enrich the secret with the endpoint -------------------
# Consumers (the Phase 2 app, psql helpers, the validation script) read one
# secret and get everything needed to connect.

resource "aws_secretsmanager_secret_version" "with_endpoint" {
  secret_id = var.secret_arn

  secret_string = jsonencode({
    username = var.master_username
    password = var.master_password
    engine   = "postgres"
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = aws_db_instance.this.db_name

    # Field name AWS itself uses, so RDS Proxy (Phase 6) and the RDS-managed
    # rotation Lambda (Phase 9) can consume this secret unmodified.
    dbInstanceIdentifier = aws_db_instance.this.identifier
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
