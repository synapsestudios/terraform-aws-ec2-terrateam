terraform {
  required_version = ">= 1.10"

  backend "local" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

locals {
  namespace = "ec2-terrateam-it"
  name      = "test"
  ami_id    = "ami-023a34a1153befb51"
  vpc_cidr  = "10.230.0.0/24"
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

  namespace        = local.namespace
  name             = local.name
  hostname         = "terrateam.test.invalid"
  github_app_url   = "https://github.com/apps/terrateam-test"
  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]
  ami_id           = local.ami_id
  data_volume_id   = aws_ebs_volume.data.id

  ssm_parameter_arns = [
    aws_ssm_parameter.github_app_id.arn,
    aws_ssm_parameter.github_app_pem.arn,
    aws_ssm_parameter.github_app_client_id.arn,
    aws_ssm_parameter.github_app_client_secret.arn,
    aws_ssm_parameter.webhook_secret.arn,
    aws_ssm_parameter.tunnel_token.arn,
    aws_ssm_parameter.postgres_password.arn,
  ]

  user_data_inputs = {
    tunnel_token_param_name        = aws_ssm_parameter.tunnel_token.name
    github_app_id_param            = aws_ssm_parameter.github_app_id.name
    github_app_pem_param           = aws_ssm_parameter.github_app_pem.name
    github_app_client_id_param     = aws_ssm_parameter.github_app_client_id.name
    github_app_client_secret_param = aws_ssm_parameter.github_app_client_secret.name
    webhook_secret_param           = aws_ssm_parameter.webhook_secret.name
    postgres_password_param        = aws_ssm_parameter.postgres_password.name
  }

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
    commands = jsonencode([file("${path.module}/scripts/health_probe.sh")])
  }

  wait_for_success_timeout_seconds = 900
}

output "terrateam_public_ip" {
  description = "Public IP of the test instance"
  value       = module.terrateam_server.public_ip
}
