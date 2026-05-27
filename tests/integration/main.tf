terraform {
  required_version = ">= 1.10"

  backend "local" {}

  required_providers {
    # AWS provider version is intentionally omitted: it derives from the module
    # under test (../../versions.tf, >= 5.0) via constraint intersection at init,
    # so there is exactly one place the AWS version policy lives. random/tls/
    # external below are this harness's own deps and keep their constraints here.
    aws = {
      source = "hashicorp/aws"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Runs a runner-side curl against the EIP to test the public ingress path
    # (the in-instance SSM probe hits localhost and can't exercise the SG/EIP).
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region = "us-west-2"

  default_tags {
    tags = {
      Environment   = "test"
      ProvisionedBy = "terraform"
      Module        = "root"
      ModuleVersion = "local"
      Test          = "terraform-aws-ec2-terrateam-integration"
    }
  }
}

variable "ingress_mode" {
  description = "Which ingress mode to exercise. Defaults to cloudflare_tunnel; the nginx_letsencrypt.tftest.hcl run overrides it."
  type        = string
  default     = "cloudflare_tunnel"
}

locals {
  namespace     = "ec2-terrateam-it"
  name          = "test"
  ami_id        = "ami-023a34a1153befb51"
  vpc_cidr      = "10.230.0.0/24"
  test_hostname = "terrateam.test.invalid"

  # Mode-aware in-instance health probe (selected by ingress_mode).
  probe_script = var.ingress_mode == "nginx_letsencrypt" ? file("${path.module}/scripts/health_probe_nginx.sh") : file("${path.module}/scripts/health_probe.sh")
}

# nginx_letsencrypt needs a stable public IP (the caller owns it). cloudflare_tunnel
# has no inbound IP, so none is created.
resource "aws_eip" "this" {
  count  = var.ingress_mode == "nginx_letsencrypt" ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.namespace}-${local.name}-eip" }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${local.namespace}-${local.name}"
  cidr = local.vpc_cidr
  azs  = ["us-west-2a"]

  public_subnets          = [cidrsubnet(local.vpc_cidr, 3, 0)]
  map_public_ip_on_launch = true

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = false
}

resource "aws_ebs_volume" "data" {
  availability_zone = "us-west-2a"
  size              = 10
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${local.namespace}-${local.name}-data" }
}

resource "aws_ssm_parameter" "github_app_id" {
  name  = "/${local.namespace}/${local.name}/github-app-id"
  type  = "SecureString"
  value = "test-app-id"
}

# terrat-oss decodes GITHUB_APP_PEM with X509.Private_key.decode_pem and refuses
# to start otherwise, so generate a real RSA key for the test rather than a
# placeholder string. The key is never used to talk to GitHub — the App ID below
# is fake — but it has to parse.
resource "tls_private_key" "github_app" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_ssm_parameter" "github_app_pem" {
  name  = "/${local.namespace}/${local.name}/github-app-pem"
  type  = "SecureString"
  value = tls_private_key.github_app.private_key_pem
}

resource "aws_ssm_parameter" "github_app_client_id" {
  name  = "/${local.namespace}/${local.name}/github-app-client-id"
  type  = "SecureString"
  value = "test-client-id"
}

resource "aws_ssm_parameter" "github_app_client_secret" {
  name  = "/${local.namespace}/${local.name}/github-app-client-secret"
  type  = "SecureString"
  value = "test-client-secret"
}

resource "aws_ssm_parameter" "webhook_secret" {
  name  = "/${local.namespace}/${local.name}/github-webhook-secret"
  type  = "SecureString"
  value = "test-webhook-secret"
}

resource "aws_ssm_parameter" "tunnel_token" {
  name  = "/${local.namespace}/${local.name}/tunnel-token"
  type  = "SecureString"
  value = "test-tunnel-token"
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "postgres_password" {
  name  = "/${local.namespace}/${local.name}/postgres-password"
  type  = "SecureString"
  value = random_password.postgres.result
}

module "terrateam_server" {
  source = "../../"

  ingress_mode      = var.ingress_mode
  eip_allocation_id = var.ingress_mode == "nginx_letsencrypt" ? aws_eip.this[0].allocation_id : null
  acme_email        = var.ingress_mode == "nginx_letsencrypt" ? "ops@test.invalid" : null

  namespace        = local.namespace
  name             = local.name
  hostname         = local.test_hostname
  github_app_url   = "https://github.com/apps/terrateam-test"
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]
  ami_id           = local.ami_id
  data_volume_id   = aws_ebs_volume.data.id

  # Tunnel token is only wired in cloudflare_tunnel mode.
  ssm_parameter_arns = concat([
    aws_ssm_parameter.github_app_id.arn,
    aws_ssm_parameter.github_app_pem.arn,
    aws_ssm_parameter.github_app_client_id.arn,
    aws_ssm_parameter.github_app_client_secret.arn,
    aws_ssm_parameter.webhook_secret.arn,
    aws_ssm_parameter.postgres_password.arn,
  ], var.ingress_mode == "cloudflare_tunnel" ? [aws_ssm_parameter.tunnel_token.arn] : [])

  user_data_inputs = merge({
    github_app_id_param            = aws_ssm_parameter.github_app_id.name
    github_app_pem_param           = aws_ssm_parameter.github_app_pem.name
    github_app_client_id_param     = aws_ssm_parameter.github_app_client_id.name
    github_app_client_secret_param = aws_ssm_parameter.github_app_client_secret.name
    webhook_secret_param           = aws_ssm_parameter.webhook_secret.name
    postgres_password_param        = aws_ssm_parameter.postgres_password.name
    }, var.ingress_mode == "cloudflare_tunnel" ? {
    tunnel_token_param_name = aws_ssm_parameter.tunnel_token.name
  } : {})

  log_group_prefix = "/${local.namespace}"
}

resource "aws_ssm_association" "wait_for_terrateam" {
  name             = "AWS-RunShellScript"
  association_name = "${local.namespace}-${local.name}-health-probe"

  targets {
    key    = "InstanceIds"
    values = [module.terrateam_server.instance_id]
  }

  parameters = {
    commands = jsonencode([local.probe_script])
  }

  # nginx_letsencrypt pulls four images (postgres + terrat-oss + nginx + certbot),
  # so allow extra headroom over the tunnel-mode cold-pull time.
  wait_for_success_timeout_seconds = 1200
}

# Public-path probe for nginx_letsencrypt: curls the EIP from the runner (outside
# the instance) so it actually traverses the security group and the EIP, unlike
# the in-instance SSM probe. Ordered after the SSM association so nginx is up.
# Always exits 0 and returns the observed HTTP codes for the test to assert on.
data "external" "ingress_probe" {
  count      = var.ingress_mode == "nginx_letsencrypt" ? 1 : 0
  depends_on = [aws_ssm_association.wait_for_terrateam]
  program    = ["bash", "${path.module}/scripts/external_probe.sh"]
  query      = { eip = aws_eip.this[0].public_ip, host = local.test_hostname }
}

output "terrateam_public_ip" {
  description = "Public IP of the test instance"
  value       = module.terrateam_server.public_ip
}
