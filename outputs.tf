output "instance_id" {
  description = "ID of the Terrateam EC2 instance"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP of the Terrateam instance (egress address only; ingress is via Cloudflare Tunnel)"
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
