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
    name = optional(string)

    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    description                  = optional(string)
    from_port                    = optional(string)
    ip_protocol                  = optional(string, "tcp")
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
    tags                         = optional(map(string), {})
    to_port                      = optional(string)
  }))
  default = {}
}

variable "additional_ingress_rules" {
  description = "Additional ingress rules to apply to the security group."
  type = map(object({
    name = optional(string)

    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    description                  = optional(string)
    from_port                    = optional(string)
    ip_protocol                  = optional(string, "tcp")
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
    tags                         = optional(map(string), {})
    to_port                      = optional(string)
  }))
  default = {}
}

variable "enable_eip" {
  description = "Whether or not to enable a consistent elastic IP for the EC2 instances."
  type        = bool
  default     = false
}

variable "enable_spot_instance" {
  description = "Whether or not to use spot instances for the ASG."
  type        = bool
  default     = false
}

variable "on_demand_base_capacity" {
  description = "Minimum number of on-demand instances in the ASG. For a single-instance ASG, set to 1 to guarantee an on-demand instance when spot is unavailable."
  type        = number
  default     = null
}

variable "on_demand_percentage_above_base_capacity" {
  description = "Percentage of instances above the base capacity that should be on-demand. Set to 100 to fall back to on-demand when spot is unavailable."
  type        = number
  default     = null
}

variable "instance_type" {
  description = "The instance type to use for the ASG. Also used as the primary instance type in the mixed instances policy."
  type        = string
  default     = "t4g.small"
}

variable "instance_type_overrides" {
  description = "Additional instance types for the mixed instances policy. Provides more capacity pools for spot and improves availability. When empty, only var.instance_type is used."
  type        = list(string)
  default     = []
}

variable "spot_allocation_strategy" {
  description = "Strategy for allocating spot instances. Valid values: 'capacity-optimized', 'capacity-optimized-prioritized', 'lowest-price', 'price-capacity-optimized'. Note: AWS recommends 'price-capacity-optimized' over 'lowest-price'."
  type        = string
  default     = "price-capacity-optimized"

  validation {
    condition     = contains(["capacity-optimized", "capacity-optimized-prioritized", "lowest-price", "price-capacity-optimized"], var.spot_allocation_strategy)
    error_message = "spot_allocation_strategy must be one of: capacity-optimized, capacity-optimized-prioritized, lowest-price, price-capacity-optimized."
  }
}

variable "spot_instance_pools" {
  description = "Number of spot instance pools across which to allocate instances. Only valid when spot_allocation_strategy is 'lowest-price'. Set to 0 for other strategies."
  type        = number
  default     = 0
}

variable "capacity_rebalance" {
  description = "Whether capacity rebalancing is enabled. When true, the ASG proactively replaces spot instances that receive a rebalance recommendation."
  type        = bool
  default     = null
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
