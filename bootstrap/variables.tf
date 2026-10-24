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

variable "github_repository" {
  description = "GitHub repository in OWNER/REPO form, used in the OIDC trust policies."
  type        = string
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
