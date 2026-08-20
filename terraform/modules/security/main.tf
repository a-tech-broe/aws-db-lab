# ---------------------------------------------------------------------------
# Security: customer-managed KMS key, master credential in Secrets Manager,
# and the security groups that enforce the app -> db path.
#
# The rule that matters: the database security group has exactly one ingress
# source -- the application security group. Not a CIDR, not 0.0.0.0/0.
# Phase 9 breaks this on purpose; this is the baseline it gets compared to.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------- KMS ------------------------------------

data "aws_iam_policy_document" "kms" {
  # Without this the key becomes unmanageable the moment it is created.
  statement {
    sid       = "EnableAccountRootIAM"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowAWSServiceUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "rds.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "monitoring.rds.amazonaws.com",
        "logs.${data.aws_region.current.region}.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "CMK for ${var.name_prefix}: RDS storage, Performance Insights, secrets, logs"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = merge(var.tags, { Name = "${var.name_prefix}-cmk" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.this.key_id
}

# ----------------------------- Secrets Manager -----------------------------

resource "random_password" "db_master" {
  length  = 32
  special = true
  # PostgreSQL master passwords cannot contain '/', '@', '"', or a space.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.name_prefix}/rds/master"
  description             = "Master credentials for the ${var.name_prefix} PostgreSQL instance"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-master" })
}

# Written once at create time. The RDS module then attaches the host/port via
# a second version so consumers get a complete connection descriptor.
resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id

  secret_string = jsonencode({
    username = var.db_master_username
    password = random_password.db_master.result
    engine   = "postgres"
    port     = var.db_port
  })

  lifecycle {
    # Phase 9 rotates this secret out of band; do not let Terraform revert it.
    ignore_changes = [secret_string]
  }
}

# ------------------------------ Security groups ----------------------------

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "Application tier (ECS Fargate). Egress to the database only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "PostgreSQL RDS. Ingress from the application tier only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Rules are separate resources on purpose: Phase 9 adds and removes an
# offending 0.0.0.0/0 rule without rewriting the security group itself.

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the application tier"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-from-app" })
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the database tier"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-to-db" })
}

# Fargate needs 443 to pull images, read Secrets Manager and push logs.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs and image registries"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-https" })
}

# Deliberately absent: any egress rule on the database security group.
# RDS does not initiate outbound connections for anything we use in Phase 1.
