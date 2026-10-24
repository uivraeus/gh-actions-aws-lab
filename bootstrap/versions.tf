terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bootstrap starts with local state (chicken-and-egg: the bucket doesn't exist yet).
  # After the first apply you can migrate it into the bucket it created:
  #   1. uncomment the block below and fill in the bucket name (see `terraform output`)
  #   2. terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "<state bucket>"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "eu-north-1"
  #   use_lockfile = true
  # }
}

# No profile/credentials here on purpose: uses the standard AWS credential chain
# (AWS_PROFILE + `aws sso login` locally).
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name_prefix
      ManagedBy = "terraform/bootstrap"
    }
  }
}
