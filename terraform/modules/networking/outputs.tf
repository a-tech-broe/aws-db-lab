output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "AZs the subnets are spread across."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT, bastion)."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private application subnet IDs (ECS Fargate)."
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "Private database subnet IDs (RDS)."
  value       = aws_subnet.private_db[*].id
}

output "private_app_subnet_cidrs" {
  description = "CIDRs of the application tier, for security group rules."
  value       = aws_subnet.private_app[*].cidr_block
}

output "db_subnet_group_name" {
  description = "Name of the RDS DB subnet group."
  value       = aws_db_subnet_group.this.name
}

output "nat_gateway_public_ips" {
  description = "Elastic IPs fronting the NAT gateways."
  value       = aws_eip.nat[*].public_ip
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group holding VPC flow logs, if enabled."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}
