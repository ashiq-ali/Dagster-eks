terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  # Uncomment and configure for remote state (recommended for teams)
  backend "s3" {
    bucket         = "hydrosat-terraform-state-143682524229"
    key            = "dagster-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "hydrosat-terraform-locks"
    encrypt        = true
  }
}
