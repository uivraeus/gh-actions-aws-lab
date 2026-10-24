variable "region" {
  description = "AWS region for the state bucket (and default region for the roles' workloads)."
  type        = string
  default     = "eu-north-1"
}

variable "name_prefix" {
  description = "Prefix for all names. Role names become <prefix>-<env>-plan / <prefix>-<env>-apply; the workflow relies on this convention."
  type        = string
  default     = "ghalab"
}

variable "github_oidc_sub_prefix" {
  description = <<-EOT
    The repo's OIDC subject claim prefix (immutable format), used in the trust policies.
    Shown under Settings > Actions > OIDC, or:
      gh api repos/OWNER/REPO/actions/oidc/customization/sub -q .sub_claim_prefix
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^@/:]+@[0-9]+/[^@/:]+@[0-9]+$", var.github_oidc_sub_prefix))
    error_message = "Expected the immutable format repo:OWNER@OWNER_ID/REPO@REPO_ID."
  }
}

variable "environments" {
  description = "Environment names. Each gets its own state key, plan role and apply role."
  type        = set(string)
  default     = ["dev", "prod"]
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one per URL is allowed)."
  type        = bool
  default     = true
}
