variable "aws_region" {
  description = "Region for the state bucket. Keep it with the primary region."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used to build resource names."
  type        = string
  default     = "awsdblab"
}

variable "github_repository" {
  description = "owner/repo that is allowed to assume the deploy role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form."
  }
}

variable "deploy_branch" {
  description = "Branch whose pushes may run apply."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider. Set false if the account already has one
    (only a single provider per URL is allowed per account) -- it is then
    looked up instead.
  EOT
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "Override the generated state bucket name. Null derives it from the account ID."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "How long superseded state versions are kept. State history is the only undo for a bad apply."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default = {
    Project   = "awsdblab"
    ManagedBy = "terraform"
    Component = "bootstrap"
  }
}
