output "public_ip" {
  value = aws_eip.nat[0].public_ip
}
