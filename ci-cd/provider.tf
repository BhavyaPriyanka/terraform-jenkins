terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.37.0"
    }
  }
  backend "s3" {
    bucket         = "localhelp-remote-state-terraform"
    key            = "jenkins/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "suri-dev"
  }
}

#provide authentication here
provider "aws" {
  region = var.aws_region

    default_tags {
    tags = local.common_tags
  }
}