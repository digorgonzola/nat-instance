output "public_ips" {
  description = "Elastic IPs of the NAT instances, keyed by availability zone."
  value       = module.nat_instance.public_ips
}
