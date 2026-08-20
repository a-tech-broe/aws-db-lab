variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
}

variable "vpc_id" {
  description = "VPC to place the host in."
  type        = string
}

variable "subnet_id" {
  description = "Private application subnet. The host reaches SSM through the NAT gateway."
  type        = string
}

variable "db_security_group_id" {
  description = "Database security group that this host is granted ingress to."
  type        = string
}

variable "db_port" {
  description = "PostgreSQL listener port."
  type        = number
  default     = 5432
}

variable "db_secret_arn" {
  description = "Secrets Manager secret the host is allowed to read."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK used to decrypt the secret and encrypt the root volume."
  type        = string
}

variable "instance_type" {
  description = "Instance type. Nothing runs here but psql and the SSM agent."
  type        = string
  default     = "t4g.nano"
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
