# =============================================================================
# GitHub Actions OIDC roles
# Two roles assumed by GitHub Actions via OIDC (no static AWS keys):
#   - plan  role: read-only refresh + state lock  (used by plan.yml on PRs)
#   - apply role: full write                        (used by apply.yml/destroy.yml)
# The OIDC provider already exists in the account (shared), so it's data-sourced,
# not recreated. Trust is scoped tightly by the GitHub `sub` claim.
# =============================================================================

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# -----------------------------------------------------------------------------
# PLAN role — assumed by pull-request runs and manual plan dispatch on main.
# Read-only everywhere + just enough to read state from S3 and take the lock.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
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
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.project_name}-gha-plan"
  description        = "GitHub Actions OIDC role - terraform plan (read-only)"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan still acquires the state lock and reads remote state, which ReadOnlyAccess
# does not permit (those are writes to DynamoDB / are object reads on the bucket).
data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "StateBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
  }

  statement {
    sid       = "StateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [var.lock_table_arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "state-access"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# -----------------------------------------------------------------------------
# APPLY role — assumed only by jobs running in the `production` environment
# (apply.yml + destroy.yml both set `environment: production`). The environment
# approval gate is the human control; the `sub` claim is the cryptographic one.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "apply" {
  name               = "${var.project_name}-gha-apply"
  description        = "GitHub Actions OIDC role - terraform apply/destroy"
  assume_role_policy = data.aws_iam_policy_document.apply_trust.json
}

# PowerUserAccess = everything except IAM/Organizations. Covers VPC, ECS, RDS,
# ElastiCache, OpenSearch, SQS, S3, CloudFront, ECR + the state backend.
resource "aws_iam_role_policy_attachment" "apply_poweruser" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# The stack creates IAM roles/instance-profiles (ECS instance + task roles), so
# the apply role needs scoped IAM. Restricted to this project's own resources;
# CreateServiceLinkedRole is needed by OpenSearch/ElastiCache and is service-gated.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PassRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::*:role/${var.project_name}-*",
      "arn:aws:iam::*:instance-profile/${var.project_name}-*",
    ]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "opensearchservice.amazonaws.com",
        "elasticache.amazonaws.com",
        "ecs.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  name   = "scoped-iam"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam.json
}
