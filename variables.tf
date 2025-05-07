variable "allowed_domains" {
  description = "List of allowed domains."
  type        = list(string)
  default = [
    ".amazonaws.com",
    ".amazon.com",
  ]
}

variable "enable_eip" {
  description = "Whether or not to enable a consistent elastic IP for the EC2 instances."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "The instance type to use for the ASG."
  type        = string
  default     = "t4g.small"
}

variable "detailed_monitoring" {
  description = "Whether or not to enable detailed monitoring for the EC2 instance."
  type        = bool
  default     = false
}

variable "private_subnet_ids" {
  description = "List of private subnet ID's in the VPC."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet ID's to deploy the ASG to."
  type        = list(string)
}

variable "vpc_id" {
  description = "The ID of the VPC to deploy the squid proxy to."
  type        = string
}
