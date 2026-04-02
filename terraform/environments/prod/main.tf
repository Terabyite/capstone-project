terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name = "taskapp.k8s.${var.domain_name}"

  common_tags = {
    Project     = var.project_name
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

module "s3" {
  source       = "../../modules/s3"
  project_name = var.project_name
  account_id   = data.aws_caller_identity.current.account_id
  tags         = local.common_tags
}

module "vpc" {
  source               = "../../modules/vpc"
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  tags                 = local.common_tags
}

module "iam" {
  source       = "../../modules/iam"
  project_name = var.project_name
  tags         = local.common_tags
}

module "dns" {
  source              = "../../modules/dns"
  domain_name         = var.domain_name
  ingress_lb_hostname = var.ingress_lb_hostname
  tags                = local.common_tags
}
