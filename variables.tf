variable "namespace" {
  description = "Namespace prefix for resource names and tags"
  type        = string
}

variable "name" {
  description = "Logical name for this instance (used in Name tags and resource names)"
  type        = string
  default     = "terrateam"
}

variable "ingress_mode" {
  description = "How inbound traffic reaches terrat-oss. 'cloudflare_tunnel' (default) runs cloudflared with zero SG ingress; 'nginx_letsencrypt' opens 80/443 and runs nginx + certbot with Let's Encrypt TLS."
  type        = string
  default     = "cloudflare_tunnel"
  validation {
    condition     = contains(["cloudflare_tunnel", "nginx_letsencrypt"], var.ingress_mode)
    error_message = "ingress_mode must be 'cloudflare_tunnel' or 'nginx_letsencrypt'."
  }
}

variable "eip_allocation_id" {
  description = "Allocation ID of a caller-owned Elastic IP to associate with the instance. Required (and only used) when ingress_mode = \"nginx_letsencrypt\": it provides a stable public IP that survives instance replacement, which the caller points a DNS A record at for Let's Encrypt issuance. The caller owns the aws_eip and the DNS record (mirrors the data-volume/DNS ownership boundary)."
  type        = string
  default     = null
  validation {
    condition     = var.ingress_mode != "nginx_letsencrypt" || var.eip_allocation_id != null
    error_message = "ingress_mode = \"nginx_letsencrypt\" requires eip_allocation_id (a caller-owned Elastic IP allocation)."
  }
}

variable "hostname" {
  description = "Public hostname terrateam is served at. Used as TERRAT_UI_BASE / TERRAT_WEB_BASE_URL inside the container; the GitHub App's OAuth callback URL must point here."
  type        = string
}

variable "github_app_url" {
  description = "Public URL of the GitHub App that operators install (e.g. https://github.com/apps/<slug>). Drives the wizard's 'Install GitHub App' button. terrat-oss defaults to the public Terrateam SaaS app when GITHUB_APP_URL is unset, which is wrong for self-hosted."
  type        = string
}

variable "vpc_id" {
  description = "VPC in which to launch the instance"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet to launch the instance in (needs internet egress for GitHub/ghcr.io and Cloudflare Tunnel)"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the instance. Pin explicitly; bumping is opt-in."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (must match AMI architecture)"
  type        = string
  default     = "t4g.small"
}

variable "data_volume_id" {
  description = "ID of the EBS volume to attach as Postgres data storage"
  type        = string
}

variable "data_device_name" {
  description = "AttachVolume device name (metadata only on Nitro; user-data resolves the actual NVMe device by serial)"
  type        = string
  default     = "/dev/sdf"
}

variable "ssm_parameter_arns" {
  description = "ARNs of SSM parameters the instance is allowed to read at boot"
  type        = list(string)
}

variable "user_data_inputs" {
  description = "Caller-supplied SSM parameter names that user-data fetches at boot. tunnel_token_param_name is only used in ingress_mode = \"cloudflare_tunnel\" and is omitted in nginx_letsencrypt mode."
  type = object({
    tunnel_token_param_name        = optional(string)
    github_app_id_param            = string
    github_app_pem_param           = string
    github_app_client_id_param     = string
    github_app_client_secret_param = string
    webhook_secret_param           = string
    postgres_password_param        = string
  })
  validation {
    condition     = var.ingress_mode != "cloudflare_tunnel" || var.user_data_inputs.tunnel_token_param_name != null
    error_message = "ingress_mode = \"cloudflare_tunnel\" requires user_data_inputs.tunnel_token_param_name (the Cloudflare Tunnel connector token SSM parameter name)."
  }
}

variable "terrateam_image_tag" {
  description = "ghcr.io/terrateamio/terrat-oss image tag. Pinned by default; override deliberately."
  type        = string
  default     = "20260429-1844-935071f"
}

variable "cloudflared_image_tag" {
  description = "cloudflare/cloudflared image tag (ingress_mode = \"cloudflare_tunnel\" only). Pinned by default; override deliberately."
  type        = string
  default     = "2026.3.0"
}

variable "nginx_image_tag" {
  description = "nginx image tag (ingress_mode = \"nginx_letsencrypt\" only). Pinned by default; override deliberately."
  type        = string
  default     = "1.27-alpine"
}

variable "certbot_image_tag" {
  description = "certbot/certbot image tag (ingress_mode = \"nginx_letsencrypt\" only). Pinned by default; override deliberately."
  type        = string
  default     = "v2.11.0"
}

variable "acme_email" {
  description = "Email registered with Let's Encrypt for expiry notices (ingress_mode = \"nginx_letsencrypt\" only). Optional; if omitted, certbot registers without an email (--register-unsafely-without-email)."
  type        = string
  default     = null
}

variable "compose_plugin_version" {
  description = "Docker Compose plugin version. AL2023's default dnf repos don't ship docker-compose-plugin; the upstream binary release is dropped into /usr/local/lib/docker/cli-plugins per https://docs.docker.com/compose/install/linux/."
  type        = string
  default     = "5.1.3"
}

variable "compose_plugin_arch" {
  description = "Architecture suffix on the docker/compose release asset (aarch64 for t4g/Graviton, x86_64 otherwise)"
  type        = string
  default     = "aarch64"
}

variable "log_group_prefix" {
  description = "CloudWatch log group prefix the instance is allowed to write to (used to scope the IAM policy)"
  type        = string
  default     = "/terrateam"
}

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}
