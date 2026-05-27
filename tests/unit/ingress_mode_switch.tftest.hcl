# Switch happy-path: a deployment changing ingress_mode in place. Kept in its own
# file because these run blocks deliberately SHARE/accumulate state (apply ->
# apply -> apply), unlike the independent assertions in ingress_mode.tftest.hcl.
# Each step asserts a clean transition and the correct end state for that mode.
#
# For the switch to actually reconfigure the host, a user_data change must recreate
# the instance (cloud-init only runs at first boot) — asserted below.

mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = {
      arn = "arn:aws:iam::123456789012:instance-profile/mock-profile"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name = "us-west-2"
    }
  }
}

variables {
  namespace        = "acme-prod"
  name             = "terrateam"
  hostname         = "terrateam.example.com"
  github_app_url   = "https://github.com/apps/terrateam-test"
  vpc_id           = "vpc-0123456789abcdef0"
  public_subnet_id = "subnet-0123456789abcdef0"
  ami_id           = "ami-023a34a1153befb51"
  instance_type    = "t4g.small"
  data_volume_id   = "vol-0123456789abcdef0"
  ssm_parameter_arns = [
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-app-id",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-app-pem",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-app-client-id",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-app-client-secret",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-webhook-secret",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/tunnel-token",
    "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/postgres-password",
  ]
  tags = {}
}

run "start_in_cloudflare_tunnel" {
  command = apply

  variables {
    ingress_mode      = "cloudflare_tunnel"
    eip_allocation_id = null
    user_data_inputs = {
      tunnel_token_param_name        = "/terrateam/tunnel-token"
      github_app_id_param            = "/terrateam/github-app-id"
      github_app_pem_param           = "/terrateam/github-app-pem"
      github_app_client_id_param     = "/terrateam/github-app-client-id"
      github_app_client_secret_param = "/terrateam/github-app-client-secret"
      webhook_secret_param           = "/terrateam/github-webhook-secret"
      postgres_password_param        = "/terrateam/postgres-password"
    }
  }

  assert {
    condition     = length(aws_security_group.this.ingress) == 0
    error_message = "initial cloudflare_tunnel deployment must have zero SG ingress"
  }

  assert {
    condition     = length(aws_eip_association.this) == 0
    error_message = "cloudflare_tunnel must not associate an EIP"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "cloudflare/cloudflared:") && !strcontains(aws_instance.this.user_data, "nginx:")
    error_message = "cloudflare_tunnel host must run cloudflared, not nginx"
  }

  # The fix that makes a later switch actually take effect on the host.
  assert {
    condition     = aws_instance.this.user_data_replace_on_change == true
    error_message = "instance must recreate on user_data change so an ingress_mode switch (and image-tag bumps) actually re-run cloud-init"
  }
}

run "switch_to_nginx_letsencrypt" {
  command = apply

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
    acme_email        = "ops@example.com"
    user_data_inputs = {
      github_app_id_param            = "/terrateam/github-app-id"
      github_app_pem_param           = "/terrateam/github-app-pem"
      github_app_client_id_param     = "/terrateam/github-app-client-id"
      github_app_client_secret_param = "/terrateam/github-app-client-secret"
      webhook_secret_param           = "/terrateam/github-webhook-secret"
      postgres_password_param        = "/terrateam/postgres-password"
    }
  }

  assert {
    condition     = length(aws_security_group.this.ingress) == 2
    error_message = "switching to nginx_letsencrypt must open 80 + 443"
  }

  assert {
    condition     = length(aws_eip_association.this) == 1
    error_message = "switching to nginx_letsencrypt must associate the caller's EIP"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "nginx:") && strcontains(aws_instance.this.user_data, "certbot/certbot:")
    error_message = "switched host must run nginx + certbot"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "cloudflare/cloudflared:") && !strcontains(aws_instance.this.user_data, "127.0.0.1:8080:8080")
    error_message = "after switching to nginx_letsencrypt, cloudflared and the loopback publish must be gone"
  }
}

run "switch_back_to_cloudflare_tunnel" {
  command = apply

  variables {
    ingress_mode      = "cloudflare_tunnel"
    eip_allocation_id = null
    user_data_inputs = {
      tunnel_token_param_name        = "/terrateam/tunnel-token"
      github_app_id_param            = "/terrateam/github-app-id"
      github_app_pem_param           = "/terrateam/github-app-pem"
      github_app_client_id_param     = "/terrateam/github-app-client-id"
      github_app_client_secret_param = "/terrateam/github-app-client-secret"
      webhook_secret_param           = "/terrateam/github-webhook-secret"
      postgres_password_param        = "/terrateam/postgres-password"
    }
  }

  # NB: we don't assert SG ingress == 0 here. aws_security_group.ingress is a
  # computed set, and mock_provider recomputes it when the config adds rules
  # (0 -> 2, asserted in switch_to_nginx) but carries the old value forward when
  # the config removes them (2 -> 0) — it can't model set removal on update. The
  # real provider revokes the rules; fresh-apply tunnel mode (no_ingress_rules_*)
  # proves zero ingress. The reliable switch-back signals here are the EIP release
  # and the reverted user_data below.
  assert {
    condition     = length(aws_eip_association.this) == 0
    error_message = "switching back to cloudflare_tunnel must release the EIP association"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "cloudflare/cloudflared:") && !strcontains(aws_instance.this.user_data, "nginx:") && !strcontains(aws_instance.this.user_data, "certbot/certbot:")
    error_message = "after switching back, the host must run cloudflared with no nginx/certbot"
  }
}
