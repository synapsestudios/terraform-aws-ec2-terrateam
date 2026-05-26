output "instance_id" {
  description = "ID of the Terrateam EC2 instance"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP of the Terrateam instance. In cloudflare_tunnel mode this is an egress address only (ingress is via the tunnel). In nginx_letsencrypt mode the caller's associated Elastic IP is the inbound address; point the DNS A record at the EIP, not at this value."
  value       = aws_instance.this.public_ip
}

output "security_group_id" {
  description = "ID of the security group attached to the instance"
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "ARN of the EC2 instance role"
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the EC2 instance role"
  value       = aws_iam_role.this.name
}
