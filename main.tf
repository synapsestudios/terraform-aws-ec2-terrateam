data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  resource_name = "${var.namespace}-${var.name}"

  resource_tags = merge(var.tags, {
    Name          = local.resource_name
    Module        = "terraform-aws-ec2-terrateam"
    ModuleVersion = "local"
  })

  log_group_arns = [
    "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_prefix}/*",
    "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_prefix}/*:*",
  ]

  cw_log_group_name = "${var.log_group_prefix}/render-secrets"

  # The compose stack is rendered from its own template fragment and injected
  # into the cloud-config below. Keeping it out of user_data.tftpl isolates the
  # ingress-specific services (cloudflared today; nginx + certbot under
  # ingress_mode = "nginx_letsencrypt") into one focused, separately-testable file.
  compose_yml = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
    ingress_mode          = var.ingress_mode
    terrateam_image_tag   = var.terrateam_image_tag
    cloudflared_image_tag = var.cloudflared_image_tag
    nginx_image_tag       = var.nginx_image_tag
    certbot_image_tag     = var.certbot_image_tag
    github_app_url        = var.github_app_url
    hostname              = var.hostname
    # Precompute the certbot registration flag so the compose template stays free
    # of conditionals: --email when acme_email is set, else unattended registration.
    certbot_email_arg = var.acme_email != null ? "--email ${var.acme_email}" : "--register-unsafely-without-email"
  })

  # nginx reverse-proxy config, rendered only in nginx_letsencrypt mode and
  # injected into the cloud-config below. Empty in tunnel mode (never referenced).
  nginx_conf = var.ingress_mode == "nginx_letsencrypt" ? templatefile("${path.module}/templates/nginx.conf.tftpl", {
    hostname = var.hostname
  }) : ""
}

resource "aws_security_group" "this" {
  name        = local.resource_name
  description = "Terrateam host: egress only. ingress_mode=cloudflare_tunnel adds no ingress (Cloudflare Tunnel is outbound); ingress_mode=nginx_letsencrypt opens 80/443."
  vpc_id      = var.vpc_id
  tags        = local.resource_tags

  # Mode-conditional ingress (see local.ingress_rules in ingress.tf). Empty list
  # in cloudflare_tunnel mode => no ingress block rendered, preserving the
  # zero-ingress posture.
  dynamic "ingress" {
    for_each = local.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "Outbound allow all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "this" {
  name = local.resource_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.resource_tags
}

resource "aws_iam_role_policy" "this" {
  name = local.resource_name
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = var.ssm_parameter_arns
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:DescribeLogStreams",
        ]
        Resource = local.log_group_arns
      },
    ]
  })
}

# Enables `aws ssm start-session` for ops without SSH.
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = local.resource_name
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.tftpl", {
    # NVMe serial = volume ID without dashes; the by-id path is stable on Nitro.
    data_volume_id_no_dashes       = replace(var.data_volume_id, "-", "")
    ingress_mode                   = var.ingress_mode
    hostname                       = var.hostname
    nginx_conf                     = local.nginx_conf
    tunnel_token_param_name        = var.user_data_inputs.tunnel_token_param_name
    github_app_id_param            = var.user_data_inputs.github_app_id_param
    github_app_pem_param           = var.user_data_inputs.github_app_pem_param
    github_app_client_id_param     = var.user_data_inputs.github_app_client_id_param
    github_app_client_secret_param = var.user_data_inputs.github_app_client_secret_param
    webhook_secret_param           = var.user_data_inputs.webhook_secret_param
    postgres_password_param        = var.user_data_inputs.postgres_password_param
    compose_plugin_version         = var.compose_plugin_version
    compose_plugin_arch            = var.compose_plugin_arch
    cw_log_group                   = local.cw_log_group_name
    log_group_prefix               = var.log_group_prefix
    compose_yml                    = local.compose_yml
  })

  # Recreate (not the default stop/start) when user_data changes, so cloud-init
  # actually re-runs the new config — e.g. an ingress_mode switch or an image-tag
  # bump. Durable state survives the recreate: Postgres lives on the external EBS
  # volume, and nginx_letsencrypt keeps its caller-owned EIP + DNS, so the public
  # address is stable. Without this, a mode switch silently no-ops on the host.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    tags        = local.resource_tags
  }

  # volume_tags would apply to every attached volume, including the externally-
  # managed aws_ebs_volume.data — causing perpetual drift against its own tags
  # (Name, Snapshot) and silently stripping the DLM-match Snapshot tag.
  tags = local.resource_tags

  # AMI bumps are opt-in; AL2023 republishes frequently.
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = var.data_device_name
  volume_id   = var.data_volume_id
  instance_id = aws_instance.this.id
}
