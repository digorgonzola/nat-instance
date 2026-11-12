output "public_ip" {
  description = "Elastic IP of the NAT instance, or null when enable_eip is false."
  value       = one(aws_eip.nat[*].public_ip)
}
