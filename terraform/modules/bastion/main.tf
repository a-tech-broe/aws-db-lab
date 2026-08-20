# ---------------------------------------------------------------------------
# Optional maintenance host.
#
# The database is private and has no route to the internet, which is correct
# and also means nothing can run psql against it until Phase 2 ships the app.
# This host closes that gap for Phase 5 (restore validation) and Phase 7
# (EXPLAIN ANALYZE) without weakening the network posture:
#
#   * no SSH key, no port 22 ingress, no public IP
#   * access is SSM Session Manager only, which is IAM-authenticated and
#     CloudTrail-audited
#   * it sits in the private app subnet and reaches SSM via the NAT gateway
#
# Default off. Enable with enable_bastion = true.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-bastion"
  description = "SSM-managed maintenance host. No inbound rules at all."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# No ingress rule exists on purpose: Session Manager works over an outbound
# connection the SSM agent initiates.

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS to SSM, Secrets Manager and package repos"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL to the database tier"
  referenced_security_group_id = var.db_security_group_id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_bastion" {
  security_group_id            = var.db_security_group_id
  description                  = "PostgreSQL from the maintenance host"
  referenced_security_group_id = aws_security_group.this.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-from-bastion" })
}

# ---------------------------------- IAM ------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-bastion"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_secret" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_secret_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "read_secret" {
  name   = "read-db-secret"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read_secret.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-bastion"
  role = aws_iam_role.this.name
}

# -------------------------------- Instance ---------------------------------

resource "aws_instance" "this" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y postgresql16 jq
  EOT

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion" })

  lifecycle {
    ignore_changes = [ami] # do not replace the host every time AL2023 ships an AMI
  }
}
