output "instance_id" {
  description = "EC2 instance ID. Connect with: aws ssm start-session --target <id>"
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Security group of the maintenance host."
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "IAM role assumed by the maintenance host."
  value       = aws_iam_role.this.arn
}
