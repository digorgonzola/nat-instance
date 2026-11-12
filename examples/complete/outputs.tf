output "public_ip" {
  description = "Elastic IP of the NAT instance."
  value       = module.nat_instance.public_ip
}
