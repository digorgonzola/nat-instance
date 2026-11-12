terraform {
  required_version = ">= 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "nat_instance" {
  source = "../../"

  name               = var.name
  vpc_id             = var.vpc_id
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids

  # One instance per AZ with private subnets, each serving its own AZ, with failover between AZs.
  availability_mode = "per_az"

  # A stable public IP per instance, which the Lambda moves to each replacement instance.
  enable_eip = true

  # Spot across several capacity pools, replaced early when AWS signals an interruption risk.
  enable_spot_instance    = true
  instance_type           = "t4g.small"
  instance_type_overrides = ["t4g.small", "t4g.medium", "c7g.medium"]
  capacity_rebalance      = true

  detailed_monitoring = true

  allowed_web_domains = [
    ".amazonaws.com",
    ".amazon.com",
    ".github.com",
  ]

  tags = {
    Environment = "test"
    Example     = "complete"
  }
}
