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
}

resource "aws_security_group" "this" {
  name        = local.resource_name
  description = "Terrateam host: egress only; ingress arrives via Cloudflare Tunnel"
  vpc_id      = var.vpc_id
  tags        = local.resource_tags

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
    hostname                       = var.hostname
    github_app_url                 = var.github_app_url
    tunnel_token_param_name        = var.user_data_inputs.tunnel_token_param_name
    github_app_id_param            = var.user_data_inputs.github_app_id_param
    github_app_pem_param           = var.user_data_inputs.github_app_pem_param
    github_app_client_id_param     = var.user_data_inputs.github_app_client_id_param
    github_app_client_secret_param = var.user_data_inputs.github_app_client_secret_param
    webhook_secret_param           = var.user_data_inputs.webhook_secret_param
    postgres_password_param        = var.user_data_inputs.postgres_password_param
    terrateam_image_tag            = var.terrateam_image_tag
    cloudflared_image_tag          = var.cloudflared_image_tag
    compose_plugin_version         = var.compose_plugin_version
    compose_plugin_arch            = var.compose_plugin_arch
    cw_log_group                   = local.cw_log_group_name
  })

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
