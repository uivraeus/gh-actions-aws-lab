data "aws_caller_identity" "current" {}

locals {
  # <prefix>-<env>-* is the pattern the plan/apply roles are scoped to.
  name = "${var.name_prefix}-${var.environment}"
}

resource "aws_s3_bucket" "app" {
  bucket = "${local.name}-app-${data.aws_caller_identity.current.account_id}"

  # Lab convenience: lets `terraform destroy` remove a non-empty bucket.
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id
  versioning_configuration {
    status = "Enabled"
  }
}
