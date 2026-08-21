output "state_bucket" {
  description = "S3 bucket holding remote state. Goes in the backend block."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "deploy_role_arn" {
  description = "Role GitHub Actions assumes. Set this as the AWS_DEPLOY_ROLE_ARN repository variable."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "GitHub OIDC provider ARN."
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
  description = "The repository settings that must be configured by hand."
  value       = <<-EOT
    gh variable set AWS_DEPLOY_ROLE_ARN --body "${aws_iam_role.deploy.arn}"
    gh variable set AWS_REGION          --body "${var.aws_region}"
    gh secret   set TF_VAR_alarm_email  --body "<your-email>"
  EOT
}
