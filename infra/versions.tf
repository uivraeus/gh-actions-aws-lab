terraform {
  required_version = ">= 1.10" # S3-native locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial config: bucket/key/region come from envs/<env>.s3.tfbackend.
  # Credentials come from the default chain (AWS_PROFILE locally, OIDC in Actions).
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.name_prefix
      Environment = var.environment
      ManagedBy   = "terraform/infra"
    }
  }
}
