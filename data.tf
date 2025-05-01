locals {
  architecture = data.aws_ec2_instance_type.this.supported_architectures[0]
}

data "aws_region" "current" {}

data "aws_caller_identity" "this" {}

data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_route_table" "private" {
  count     = length(var.private_subnet_ids)
  subnet_id = var.private_subnet_ids[count.index]
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*${local.architecture}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
