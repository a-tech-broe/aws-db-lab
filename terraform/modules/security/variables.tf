variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "db_port" {
  description = "PostgreSQL listener port."
  type        = number
  default     = 5432
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled CMK deletion completes."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "db_master_username" {
  description = "Master username stored in Secrets Manager and used by the RDS instance."
  type        = string
  default     = "dbadmin"

  validation {
    condition     = !contains(["postgres", "admin", "rdsadmin"], lower(var.db_master_username))
    error_message = "Avoid reserved/obvious master usernames (postgres, admin, rdsadmin)."
  }
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window. 0 deletes immediately -- convenient for a lab that is torn down often."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
