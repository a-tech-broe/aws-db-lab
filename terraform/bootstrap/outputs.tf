output "state_bucket" {
  description = "S3 bucket holding remote state. Goes in the backend block."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "deploy_role_arn" {
  description = "Role GitHub Actions assumes. Null when create_deploy_role is false."
  value       = try(aws_iam_role.deploy[0].arn, null)
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN. Null when create_deploy_role is false."
  value       = local.oidc_provider_arn
}

output "backend_block" {
  description = "Paste-ready backend configuration for terraform/environments/dev/versions.tf."
  value       = <<-EOT
    backend "s3" {
      bucket       = "${aws_s3_bucket.state.id}"
      key          = "aws-db-lab/dev/terraform.tfstate"
      region       = "${var.aws_region}"
      encrypt      = true
      use_lockfile = true
    }
  EOT
}

output "github_setup" {
  description = "Repository settings that must be configured by hand."
  value = var.create_deploy_role ? join("\n", [
    "gh variable set AWS_DEPLOY_ROLE_ARN --body '${try(aws_iam_role.deploy[0].arn, "")}'",
    "gh variable set AWS_REGION          --body '${var.aws_region}'",
    "gh secret   set TF_VAR_ALARM_EMAIL  --body '<your-email>'",
    ]) : join("\n", [
    "# Using static keys: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION are already set.",
    "gh secret set TF_VAR_ALARM_EMAIL --body '<your-email>'",
  ])
}
