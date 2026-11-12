variable "aws_region" {
  description = "AWS region to deploy resources to."
  type        = string
  default     = "ap-southeast-2"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "nat-minimal"
}

variable "vpc_id" {
  description = "ID of an existing VPC."
  type        = string
}

variable "public_subnet_ids" {
  description = "IDs of existing public subnets for the NAT instance."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "IDs of existing private subnets whose default route goes through the NAT instance."
  type        = list(string)
}
