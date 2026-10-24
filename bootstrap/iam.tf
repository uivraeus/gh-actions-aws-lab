locals {
  oidc_host = "token.actions.githubusercontent.com"

  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  # Must match infra/envs/<env>.s3.tfbackend
  state_key = { for env in var.environments : env => "envs/${env}/terraform.tfstate" }

  # Everything the infra/ root manages for an env must match this name pattern;
  # it is what scopes the roles' workload permissions.
  workload_bucket_arn = { for env in var.environments : env => "arn:aws:s3:::${var.name_prefix}-${env}-*" }
}

# AWS no longer validates thumbprints for GitHub's OIDC endpoint, so none is given.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://${local.oidc_host}"
}

# ---------------------------------------------------------------------------
# Trust policies
#
# The OIDC `sub` claim is what separates the two roles:
#   - a job WITHOUT `environment:` triggered by a PR  -> repo:OWNER/REPO:pull_request
#   - a job WITH `environment: dev`                   -> repo:OWNER/REPO:environment:dev
#
# The apply role only trusts the environment subject, and the GitHub environment
# only allows deployments from `main` (see gh-setup.sh). So a PR that edits the
# workflow to request the apply role still can't get it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "trust_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  for_each = var.environments

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["repo:${var.github_repository}:environment:${each.key}"]
    }
  }
}

# ---------------------------------------------------------------------------
# Plan role: read-only on the env's workload + read its own state + lock file
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "plan" {
  for_each = var.environments

  # The S3 backend lists the bucket during init (workspace discovery). This only
  # exposes key names, not contents.
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key[each.key]}"]
  }

  # use_lockfile = true writes <key>.tflock during plan. Drop this statement and
  # run `terraform plan -lock=false` if you want plan to be strictly read-only.
  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key[each.key]}.tflock"]
  }

  # Bucket-level config reads that the aws_s3_bucket* resources refresh.
  # Resource is the bucket ARN only (no /*), so object contents are not readable.
  statement {
    sid       = "WorkloadRead"
    actions   = ["s3:Get*", "s3:List*"]
    resources = [local.workload_bucket_arn[each.key]]
  }
}

resource "aws_iam_role" "plan" {
  for_each = var.environments

  name               = "${var.name_prefix}-${each.key}-plan"
  description        = "GitHub Actions: terraform plan for ${each.key} (PRs)"
  assume_role_policy = data.aws_iam_policy_document.trust_plan.json
}

resource "aws_iam_role_policy" "plan" {
  for_each = var.environments

  name   = "terraform-plan"
  role   = aws_iam_role.plan[each.key].id
  policy = data.aws_iam_policy_document.plan[each.key].json
}

# ---------------------------------------------------------------------------
# Apply role: read/write the env's state + full control of the env's workload
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "apply" {
  for_each = var.environments

  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid     = "StateReadWrite"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${aws_s3_bucket.state.arn}/${local.state_key[each.key]}",
    ]
  }

  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_key[each.key]}.tflock"]
  }

  statement {
    sid     = "WorkloadManage"
    actions = ["s3:*"]
    resources = [
      local.workload_bucket_arn[each.key],
      "${local.workload_bucket_arn[each.key]}/*",
    ]
  }
}

resource "aws_iam_role" "apply" {
  for_each = var.environments

  name               = "${var.name_prefix}-${each.key}-apply"
  description        = "GitHub Actions: terraform apply for ${each.key} (main, via GitHub environment)"
  assume_role_policy = data.aws_iam_policy_document.trust_apply[each.key].json
}

resource "aws_iam_role_policy" "apply" {
  for_each = var.environments

  name   = "terraform-apply"
  role   = aws_iam_role.apply[each.key].id
  policy = data.aws_iam_policy_document.apply[each.key].json
}
