output "public_ip" {
  description = "Elastic IP of the NAT instance, or null when enable_eip is false or availability_mode is per_az."
  value       = try(aws_eip.nat["single"].public_ip, null)
}

output "public_ips" {
  description = "Elastic IPs of the NAT instances, keyed by availability zone in per_az mode or \"single\" in single mode. Empty when enable_eip is false. Traffic can leave from any of them, so third-party allowlists need all of them."
  value       = { for key, eip in aws_eip.nat : key => eip.public_ip }
}
