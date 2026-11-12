output "public_ip" {
  description = "Elastic IP of the NAT instance. Null because the EIP is disabled in this example."
  value       = module.nat_instance.public_ip
}
