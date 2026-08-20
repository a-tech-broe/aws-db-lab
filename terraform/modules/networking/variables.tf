variable "name_prefix" {
  description = "Prefix applied to every resource name (e.g. awsdblab-dev)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough for 3 tiers x 3 AZs."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR of /20 or larger."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to spread the subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (Multi-AZ RDS needs at least 2)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    true  -> one NAT Gateway shared by every private subnet (cheap, single AZ failure domain).
    false -> one NAT Gateway per AZ (production posture, ~$32/AZ/month extra).
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Ship VPC Flow Logs to CloudWatch Logs. Needed for Phase 9 (security incident) forensics."
  type        = bool
  default     = true
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 14
}

variable "kms_key_arn" {
  description = "KMS CMK used to encrypt the flow log group. Null uses the CloudWatch Logs service key."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
