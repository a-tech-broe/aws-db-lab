output "sns_topic_arn" {
  description = "SNS topic every alarm publishes to."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Every CloudWatch alarm created by this module."
  value = compact(concat(
    [
      aws_cloudwatch_metric_alarm.instance_unreachable.alarm_name,
      aws_cloudwatch_metric_alarm.cpu_high.alarm_name,
      aws_cloudwatch_metric_alarm.storage_low.alarm_name,
      aws_cloudwatch_metric_alarm.memory_low.alarm_name,
      aws_cloudwatch_metric_alarm.connections_high.alarm_name,
      aws_cloudwatch_metric_alarm.read_latency_high.alarm_name,
      aws_cloudwatch_metric_alarm.write_latency_high.alarm_name,
    ],
    aws_cloudwatch_metric_alarm.cpu_credit_low[*].alarm_name,
    aws_cloudwatch_metric_alarm.replica_lag[*].alarm_name,
  ))
}

output "dashboard_name" {
  description = "CloudWatch dashboard name, if created."
  value       = try(aws_cloudwatch_dashboard.this[0].dashboard_name, null)
}

output "computed_thresholds" {
  description = "Resolved absolute thresholds, so the validation script can assert against them."
  value = {
    free_storage_bytes = local.free_storage_threshold_bytes
    freeable_memory    = local.freeable_memory_threshold
    connections        = local.connection_threshold
    cpu_percent        = var.cpu_threshold_percent
  }
}
