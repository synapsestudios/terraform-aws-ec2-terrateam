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

# Optional Route 53 A record for var.hostname, only when the caller hands over a
# hosted zone. It targets the EIP (looked up from the allocation id the module
# already receives), not aws_instance.this.public_ip: the EIP exists before the
# apply starts, so the record is created in parallel with the instance and is
# never touched by instance replacement — which user_data_replace_on_change
# forces on every mode switch and image bump. Pointing at the instance would
# re-point DNS only after the new host had already run certbot once.
#
# A plain A record with a TTL is the only option for a single host: Route 53
# alias records cannot target an IP address. allow_overwrite is false (its
# default, stated explicitly) so the module never silently replaces a hand-made
# record: a caller adopting route53_zone_id over one must import or delete it.
data "aws_eip" "this" {
  count = var.route53_zone_id != null ? 1 : 0
  id    = var.eip_allocation_id
}

resource "aws_route53_record" "this" {
  count   = var.route53_zone_id != null ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 60
  records = [data.aws_eip.this[0].public_ip]

  allow_overwrite = false
}
