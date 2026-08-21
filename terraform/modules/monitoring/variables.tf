variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance identifier the alarms watch."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK used to encrypt the SNS topic."
  type        = string
}

variable "alarm_email" {
  description = <<-EOT
    Address subscribed to the alarm topic. Leave null to create the topic
    without a subscription (alarms still fire and are visible in CloudWatch).
    AWS sends a confirmation mail that must be clicked before delivery starts.
  EOT
  type        = string
  default     = null
}

variable "instance_memory_bytes" {
  description = <<-EOT
    Physical memory of the chosen instance class, used to derive the
    FreeableMemory threshold. db.t4g.medium = 4 GiB.
  EOT
  type        = number
  default     = 4294967296
}

variable "allocated_storage_bytes" {
  description = "Allocated storage in bytes, used to derive the FreeStorageSpace threshold."
  type        = number
  default     = 53687091200 # 50 GiB
}

variable "max_connections" {
  description = <<-EOT
    Expected max_connections for the instance class. RDS PostgreSQL default is
    LEAST({DBInstanceClassMemory/9531392}, 5000); for db.t4g.medium that is ~450.
    Phase 6 drives DatabaseConnections into this ceiling on purpose.
  EOT
  type        = number
  default     = 450
}

variable "is_burstable_instance" {
  description = <<-EOT
    True for db.t3/t4g classes, which publish CPUCreditBalance. Burstable
    instances throttle to their baseline once credits run out, so CPU can look
    healthy while throughput collapses -- that needs its own alarm.
  EOT
  type        = bool
  default     = true
}

variable "cpu_credit_threshold" {
  description = "CPUCreditBalance below this counts as 'nearly exhausted' for the burstable alarm."
  type        = number
  default     = 30
}

variable "cpu_credit_cpu_floor" {
  description = <<-EOT
    CPU must also be above this for the credit alarm to fire. Without it the
    alarm trips on every freshly created instance, which starts at zero
    credits and idles at single-digit CPU.
  EOT
  type        = number
  default     = 40
}

variable "cpu_threshold_percent" {
  description = "CPUUtilization alarm threshold."
  type        = number
  default     = 80
}

variable "connection_threshold_percent" {
  description = "Percentage of max_connections that trips the connection alarm."
  type        = number
  default     = 80
}

variable "free_storage_threshold_percent" {
  description = "Trip the storage alarm when free space falls below this percentage of allocated storage."
  type        = number
  default     = 20
}

variable "freeable_memory_threshold_percent" {
  description = "Trip the memory alarm when freeable memory falls below this percentage of instance memory."
  type        = number
  default     = 10
}

variable "read_latency_threshold_seconds" {
  description = "ReadLatency alarm threshold in seconds."
  type        = number
  default     = 0.05
}

variable "write_latency_threshold_seconds" {
  description = "WriteLatency alarm threshold in seconds."
  type        = number
  default     = 0.05
}

variable "replica_lag_threshold_seconds" {
  description = "ReplicaLag alarm threshold. Only used when create_replica_lag_alarm is true (Phase 8)."
  type        = number
  default     = 30
}

variable "create_replica_lag_alarm" {
  description = "Create the replication lag alarm. Enable once a read replica exists (Phase 8)."
  type        = bool
  default     = false
}

variable "alarm_period_seconds" {
  description = "Evaluation period for the alarms."
  type        = number
  default     = 60
}

variable "alarm_evaluation_periods" {
  description = "Consecutive periods a metric must breach before the alarm fires."
  type        = number
  default     = 3
}

variable "create_dashboard" {
  description = "Create the Phase 1 CloudWatch dashboard."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
