# ---------------------------------------------------------------------------
# Monitoring: an encrypted SNS topic plus the CloudWatch alarms that cover the
# four Phase 1 signals -- availability, CPU, storage and connections -- with
# memory and latency added because they are what actually page you first.
#
# Thresholds are expressed as percentages of the instance's real capacity, so
# resizing the instance class does not silently invalidate every alarm.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  dimensions = { DBInstanceIdentifier = var.db_instance_id }

  free_storage_threshold_bytes = var.allocated_storage_bytes * (var.free_storage_threshold_percent / 100)
  freeable_memory_threshold    = var.instance_memory_bytes * (var.freeable_memory_threshold_percent / 100)
  connection_threshold         = ceil(var.max_connections * (var.connection_threshold_percent / 100))

  alarm_actions = [aws_sns_topic.alarms.arn]
}

# ---------------------------------- SNS ------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${var.name_prefix}-db-alarms"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-alarms" })
}

data "aws_iam_policy_document" "sns" {
  statement {
    sid       = "AllowCloudWatchAlarmsToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.sns.json
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --------------------------- Availability ----------------------------------
# There is no "instance is up" metric. DatabaseConnections going to no data
# means the instance stopped reporting, which is the closest CloudWatch-native
# availability signal short of the Phase 2 /db-health probe.

resource "aws_cloudwatch_metric_alarm" "instance_unreachable" {
  alarm_name        = "${var.name_prefix}-rds-no-metrics"
  alarm_description = "RDS stopped publishing metrics -- instance rebooting, failing over or stopped. Runbook: runbooks/rds-unavailable.md"

  namespace   = "AWS/RDS"
  metric_name = "DatabaseConnections"
  dimensions  = local.dimensions
  statistic   = "Sum"

  comparison_operator = "LessThanThreshold"
  threshold           = 0
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods

  # The point of this alarm: treat missing data as the failure, not as OK.
  treat_missing_data = "breaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "availability" })
}

# ------------------------------- CPU ---------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name        = "${var.name_prefix}-rds-cpu-high"
  alarm_description = "CPUUtilization above ${var.cpu_threshold_percent}%. Runbook: runbooks/high-cpu.md"

  namespace   = "AWS/RDS"
  metric_name = "CPUUtilization"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.cpu_threshold_percent
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "saturation" })
}

# Burstable classes hide CPU exhaustion behind credit depletion: CPU looks
# fine at 40% because the instance is being throttled to its baseline.
resource "aws_cloudwatch_metric_alarm" "cpu_credit_low" {
  count = var.is_burstable_instance ? 1 : 0

  alarm_name        = "${var.name_prefix}-rds-cpu-credits-low"
  alarm_description = "CPU credit balance nearly exhausted on a burstable instance -- sustained throughput is about to be throttled to baseline. Runbook: runbooks/high-cpu.md"

  namespace   = "AWS/RDS"
  metric_name = "CPUCreditBalance"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "LessThanThreshold"
  threshold           = 30
  period              = 300
  evaluation_periods  = 2

  # Non-burstable classes never publish this metric; do not page for that.
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "saturation" })
}

# ------------------------------ Storage ------------------------------------

resource "aws_cloudwatch_metric_alarm" "storage_low" {
  alarm_name        = "${var.name_prefix}-rds-storage-low"
  alarm_description = "FreeStorageSpace below ${var.free_storage_threshold_percent}% of allocated storage. Runbook: runbooks/high-storage.md"

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "LessThanThreshold"
  threshold           = local.free_storage_threshold_bytes
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "saturation" })
}

# ------------------------------- Memory ------------------------------------

resource "aws_cloudwatch_metric_alarm" "memory_low" {
  alarm_name        = "${var.name_prefix}-rds-memory-low"
  alarm_description = "FreeableMemory below ${var.freeable_memory_threshold_percent}% of instance memory -- expect swapping and latency. Runbook: runbooks/high-cpu.md"

  namespace   = "AWS/RDS"
  metric_name = "FreeableMemory"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "LessThanThreshold"
  threshold           = local.freeable_memory_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = 5
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "saturation" })
}

# ----------------------------- Connections ---------------------------------

resource "aws_cloudwatch_metric_alarm" "connections_high" {
  alarm_name        = "${var.name_prefix}-rds-connections-high"
  alarm_description = "DatabaseConnections above ${var.connection_threshold_percent}% of max_connections (${local.connection_threshold} of ${var.max_connections}). Runbook: runbooks/connection-exhaustion.md"

  namespace   = "AWS/RDS"
  metric_name = "DatabaseConnections"
  dimensions  = local.dimensions
  statistic   = "Maximum"

  comparison_operator = "GreaterThanThreshold"
  threshold           = local.connection_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = 2
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "saturation" })
}

# ------------------------------ Latency ------------------------------------

resource "aws_cloudwatch_metric_alarm" "read_latency_high" {
  alarm_name        = "${var.name_prefix}-rds-read-latency-high"
  alarm_description = "ReadLatency above ${var.read_latency_threshold_seconds}s. Runbook: runbooks/slow-query.md"

  namespace   = "AWS/RDS"
  metric_name = "ReadLatency"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.read_latency_threshold_seconds
  period              = var.alarm_period_seconds
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching" # an idle instance does no reads

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "latency" })
}

resource "aws_cloudwatch_metric_alarm" "write_latency_high" {
  alarm_name        = "${var.name_prefix}-rds-write-latency-high"
  alarm_description = "WriteLatency above ${var.write_latency_threshold_seconds}s. Runbook: runbooks/slow-query.md"

  namespace   = "AWS/RDS"
  metric_name = "WriteLatency"
  dimensions  = local.dimensions
  statistic   = "Average"

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.write_latency_threshold_seconds
  period              = var.alarm_period_seconds
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "latency" })
}

# --------------------------- Replication (Phase 8) -------------------------

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count = var.create_replica_lag_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-rds-replica-lag-high"
  alarm_description = "ReplicaLag above ${var.replica_lag_threshold_seconds}s. Runbook: runbooks/replication-lag.md"

  namespace   = "AWS/RDS"
  metric_name = "ReplicaLag"
  dimensions  = local.dimensions
  statistic   = "Maximum"

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.replica_lag_threshold_seconds
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(var.tags, { Signal = "replication" })
}

# ------------------------------ Dashboard ----------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${var.name_prefix}-database"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU utilization (%)"
          region  = data.aws_region.current.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 60
          metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id]]
          yAxis   = { left = { min = 0, max = 100 } }
          annotations = {
            horizontal = [{ label = "alarm", value = var.cpu_threshold_percent }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Database connections"
          region  = data.aws_region.current.region
          view    = "timeSeries"
          stat    = "Maximum"
          period  = 60
          metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id]]
          annotations = {
            horizontal = [
              { label = "alarm", value = local.connection_threshold },
              { label = "max_connections", value = var.max_connections },
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Free storage / freeable memory (bytes)"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id],
            [".", "FreeableMemory", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Read / write latency (seconds)"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.db_instance_id],
            [".", "WriteLatency", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "IOPS"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", var.db_instance_id],
            [".", "WriteIOPS", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Transactions and deadlocks"
          region = data.aws_region.current.region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/RDS", "TransactionLogsDiskUsage", "DBInstanceIdentifier", var.db_instance_id],
            [".", "Deadlocks", ".", "."],
          ]
        }
      },
    ]
  })
}
