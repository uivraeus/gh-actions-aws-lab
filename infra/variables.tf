variable "environment" {
  description = "Environment name (dev, prod, ...). Must match the backend file and IAM roles."
  type        = string
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "name_prefix" {
  description = "Must match bootstrap's name_prefix: the IAM roles only allow buckets named <prefix>-<env>-*."
  type        = string
  default     = "ghalab"
}
