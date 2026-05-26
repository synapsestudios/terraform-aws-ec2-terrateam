# All ingress-mode-specific wiring lives here so that, if the per-mode surface
# keeps growing, splitting ingress into its own module is a mechanical move
# rather than a rewrite. The ingress-agnostic core (instance, IAM, SSM secrets,
# EBS, observability) stays in main.tf / rotation.tf.

locals {
  # Security-group ingress per mode. cloudflare_tunnel keeps zero ingress (the
  # host is reachable only via cloudflared's outbound tunnel); nginx_letsencrypt
  # opens 80 (ACME HTTP-01 webroot + HTTP->HTTPS redirect) and 443 (HTTPS).
  ingress_rules = var.ingress_mode == "nginx_letsencrypt" ? [
    {
      description = "ACME HTTP-01 challenge and HTTP to HTTPS redirect"
      from_port   = 80
      to_port     = 80
    },
    {
      description = "HTTPS (nginx reverse proxy, Lets Encrypt TLS)"
      from_port   = 443
      to_port     = 443
    },
  ] : []
}

# Associate the caller-owned Elastic IP in nginx_letsencrypt mode so the public
# address survives instance replacement (the caller's DNS A record and Let's
# Encrypt issuance both depend on a stable IP). The caller owns the aws_eip
# itself; the module only associates it. cloudflare_tunnel mode has no inbound
# IP, so no association.
resource "aws_eip_association" "this" {
  count         = var.ingress_mode == "nginx_letsencrypt" ? 1 : 0
  instance_id   = aws_instance.this.id
  allocation_id = var.eip_allocation_id
}
