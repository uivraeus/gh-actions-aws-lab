output "account_id" {
  value = local.account_id
}

output "region" {
  value = var.region
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "plan_role_arns" {
  value = { for env, r in aws_iam_role.plan : env => r.arn }
}

output "apply_role_arns" {
  value = { for env, r in aws_iam_role.apply : env => r.arn }
}

output "backend_files" {
  description = "Contents for infra/envs/<env>.s3.tfbackend"
  value = { for env in var.environments : env => <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "${local.state_key[env]}"
    region       = "${var.region}"
    use_lockfile = true
  EOT
  }
}

output "name_prefix" {
  value = var.name_prefix
}
