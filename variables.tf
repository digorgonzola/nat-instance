variable "allowed_web_domains" {
  description = "List of allowed domains."
  type        = list(string)
  default = [
    ".amazonaws.com",
    ".amazon.com",
  ]
}

variable "architectures" {
  description = "Lambda function architecture."
  type        = list(string)
  default     = ["arm64"]
}

variable "detailed_monitoring" {
  description = "Whether or not to enable detailed monitoring for the EC2 instance."
  type        = bool
  default     = false
}

variable "additional_egress_rules" {
  description = "Additional egress rules to apply to the security group."
  type = map(object({
    cidr_ipv4   = string
    description = optional(string, null)
    ip_protocol = string
    from_port   = number
    to_port     = number
  }))
  default = null
}

variable "additional_ingress_rules" {
  description = "Additional ingress rules to apply to the security group."
  type = map(object({
    cidr_ipv4   = string
    description = optional(string, null)
    ip_protocol = string
    from_port   = number
    to_port     = number
  }))
  default = null
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

variable "name" {
  description = "The name to use for resources."
  type        = string
  default     = "nat"
}

variable "private_subnet_ids" {
  description = "List of private subnet ID's in the VPC."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet ID's to deploy the ASG to."
  type        = list(string)
}

variable "tags" {
  description = "Tags to apply to the resources."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "The ID of the VPC to deploy the NAT instance/squid proxy to."
  type        = string
}
