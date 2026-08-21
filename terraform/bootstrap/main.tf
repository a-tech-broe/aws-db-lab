# ---------------------------------------------------------------------------
# Bootstrap: the two things that must exist before CI can run Terraform.
#
#   1. An S3 bucket holding remote state, so the pipeline and the operator
#      share one source of truth instead of each having their own.
#   2. A GitHub OIDC provider and deploy role, so Actions authenticates with a
#      short-lived token instead of a long-lived access key in a secret.
#
# Applied once, by hand, with local state. See README.md in this directory.
# ---------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket = coalesce(
    var.state_bucket_name,
    "${data.aws_caller_identity.current.account_id}-${var.project}-tfstate-${var.aws_region}"
  )

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ------------------------------ State bucket -------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # State is not recreatable. Make deleting it an explicit, deliberate act.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the only recovery path from a corrupted or truncated state
# file. Without it, a bad write is permanent.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 rather than the project CMK on purpose: the CMK is created by
      # the dev environment, whose state lives in this bucket. Depending on it
      # here would mean the state could not be read to manage the key.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ------------------------------- GitHub OIDC -------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

# The trust policy is the security boundary. `sub` is pinned to this repository
# and to two contexts only: pushes to the deploy branch, and pull_request runs.
# Without the sub condition, ANY GitHub repository could assume this role.
data "aws_iam_policy_document" "deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/${var.deploy_branch}",
        "repo:${var.github_repository}:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.project}-github-deploy"
  description          = "Assumed by GitHub Actions in ${var.github_repository} to run Terraform"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600

  tags = var.tags
}

# --------------------------- Deploy permissions ----------------------------

data "aws_iam_policy_document" "deploy_state" {
  statement {
    sid       = "ReadStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    # use_lockfile writes a sibling .tflock object, so the whole prefix is needed.
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "deploy_state" {
  name   = "terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_state.json
}

data "aws_iam_policy_document" "deploy_infra" {
  # Networking, database, observability and secrets. Most of these APIs do not
  # support resource-level permissions on create, so the grant is service-wide.
  statement {
    sid    = "ManageProjectInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:*",
      "rds:*",
      "kms:*",
      "secretsmanager:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory",
      "pi:GetResourceMetrics",
      "pi:DescribeDimensionKeys",
    ]
    resources = ["*"]
  }

  # IAM is the dangerous one: unscoped, it lets the pipeline grant itself
  # anything. Restrict it to the roles this project actually creates -- the
  # RDS Enhanced Monitoring role, the flow-logs role, and the bastion role.
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:PassRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project}-*",
    ]
  }

  # RDS and VPC flow logs need their service-linked roles to exist.
  statement {
    sid       = "CreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "rds.amazonaws.com",
        "monitoring.rds.amazonaws.com",
      ]
    }
  }

  # Read-only IAM, needed by Terraform to refresh policy attachments.
  statement {
    sid    = "ReadIAM"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListRoles",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  # The pipeline must never be able to rewrite its own trust policy or grants.
  statement {
    sid    = "DenySelfEscalation"
    effect = "Deny"
    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [aws_iam_role.deploy.arn]
  }

  # Nor tamper with the bucket that records what it did.
  statement {
    sid    = "DenyStateBucketAdmin"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [aws_s3_bucket.state.arn]
  }
}

resource "aws_iam_role_policy" "deploy_infra" {
  name   = "terraform-infrastructure"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_infra.json
}
