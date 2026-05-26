# Unit tests for the ingress_mode switch: validation, security-group ingress,
# EIP association, tunnel-token optionality, and the rendered compose/nginx
# config per mode. The default-mode (cloudflare_tunnel) behavior is pinned by
# module.tftest.hcl; here we exercise what varies between modes.

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
  user_data_inputs = {
    tunnel_token_param_name        = "/terrateam/tunnel-token"
    github_app_id_param            = "/terrateam/github-app-id"
    github_app_pem_param           = "/terrateam/github-app-pem"
    github_app_client_id_param     = "/terrateam/github-app-client-id"
    github_app_client_secret_param = "/terrateam/github-app-client-secret"
    webhook_secret_param           = "/terrateam/github-webhook-secret"
    postgres_password_param        = "/terrateam/postgres-password"
  }
  tags = {}
}

run "ingress_mode_defaults_to_cloudflare_tunnel" {
  command = plan

  assert {
    condition     = var.ingress_mode == "cloudflare_tunnel"
    error_message = "ingress_mode must default to cloudflare_tunnel so existing deployers are unaffected"
  }
}

run "ingress_mode_rejects_invalid_value" {
  command = plan

  variables {
    ingress_mode = "bogus"
  }

  expect_failures = [var.ingress_mode]
}

run "nginx_mode_opens_80_and_443" {
  # apply (not plan): aws_security_group.ingress is a computed set the provider
  # leaves unknown at plan time, so the assertion can't evaluate under plan even
  # with mock_provider — same reason module.tftest.hcl's tunnel-mode check applies.
  command = apply

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
  }

  assert {
    condition     = length(aws_security_group.this.ingress) == 2
    error_message = "nginx_letsencrypt must open exactly two ingress ports (80 and 443)"
  }

  assert {
    condition     = toset([for r in aws_security_group.this.ingress : r.from_port]) == toset([80, 443])
    error_message = "nginx_letsencrypt ingress must open ports 80 (ACME HTTP-01 + redirect) and 443 (HTTPS)"
  }

  assert {
    condition = alltrue([
      for r in aws_security_group.this.ingress : contains(r.cidr_blocks, "0.0.0.0/0")
    ])
    error_message = "nginx_letsencrypt ingress must accept traffic from 0.0.0.0/0"
  }
}

run "eip_associated_in_nginx_mode" {
  command = plan

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
  }

  assert {
    condition     = length(aws_eip_association.this) == 1
    error_message = "nginx_letsencrypt must associate the caller-supplied EIP so the IP survives instance replacement"
  }

  assert {
    condition     = aws_eip_association.this[0].allocation_id == "eipalloc-0123456789abcdef0"
    error_message = "EIP association must use the caller-supplied allocation id"
  }
}

run "no_eip_in_tunnel_mode" {
  command = plan

  assert {
    condition     = length(aws_eip_association.this) == 0
    error_message = "cloudflare_tunnel mode must not associate an EIP — the caller owns no inbound IP"
  }
}

run "nginx_mode_requires_eip_allocation_id" {
  command = plan

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = null
  }

  expect_failures = [var.eip_allocation_id]
}

run "tunnel_token_absent_from_render_secrets_in_nginx_mode" {
  command = plan

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
    # nginx_letsencrypt callers omit the tunnel token entirely.
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
    condition     = !strcontains(aws_instance.this.user_data, "TERRATEAM_TUNNEL_TOKEN=$tunnel_token")
    error_message = "render-secrets must not write the tunnel token to .env when no tunnel_token_param_name is supplied"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "tunnel_token=$(get_value")
    error_message = "render-secrets must not fetch a tunnel token when no tunnel_token_param_name is supplied"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "/terrateam/tunnel-token")
    error_message = "render-secrets --names must not include the tunnel-token param when it is omitted"
  }
}

run "rotation_event_pattern_excludes_null_param_in_nginx_mode" {
  command = plan

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
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
    condition     = length(jsondecode(aws_cloudwatch_event_rule.ssm_param_change.event_pattern).detail.name) == 6
    error_message = "EventBridge rule must watch exactly the 6 supplied params (no null tunnel-token entry) in nginx mode"
  }

  assert {
    condition = alltrue([
      for n in jsondecode(aws_cloudwatch_event_rule.ssm_param_change.event_pattern).detail.name : n != null
    ])
    error_message = "EventBridge rule detail.name must not contain null — compact out the omitted tunnel-token param"
  }
}

run "cloudflare_tunnel_requires_tunnel_token" {
  command = plan

  variables {
    user_data_inputs = {
      tunnel_token_param_name        = null
      github_app_id_param            = "/terrateam/github-app-id"
      github_app_pem_param           = "/terrateam/github-app-pem"
      github_app_client_id_param     = "/terrateam/github-app-client-id"
      github_app_client_secret_param = "/terrateam/github-app-client-secret"
      webhook_secret_param           = "/terrateam/github-webhook-secret"
      postgres_password_param        = "/terrateam/postgres-password"
    }
  }

  expect_failures = [var.user_data_inputs]
}

run "tunnel_mode_compose_runs_cloudflared_only" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "cloudflare/cloudflared:")
    error_message = "cloudflare_tunnel mode must run the cloudflared service"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "127.0.0.1:8080:8080")
    error_message = "cloudflare_tunnel mode must publish terrateam on 127.0.0.1:8080 for cloudflared"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "nginx:")
    error_message = "cloudflare_tunnel mode must not run nginx"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "certbot/certbot:")
    error_message = "cloudflare_tunnel mode must not run certbot"
  }
}

run "nginx_mode_compose_runs_nginx_and_certbot" {
  command = plan

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
    condition     = strcontains(aws_instance.this.user_data, "nginx:")
    error_message = "nginx_letsencrypt mode must run the nginx service"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "certbot/certbot:")
    error_message = "nginx_letsencrypt mode must run the certbot service"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "cloudflare/cloudflared:")
    error_message = "nginx_letsencrypt mode must not run cloudflared"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "\"80:80\"") && strcontains(aws_instance.this.user_data, "\"443:443\"")
    error_message = "nginx must publish 80 and 443 on the host"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "127.0.0.1:8080:8080")
    error_message = "nginx_letsencrypt mode must not host-publish terrateam; nginx reaches it over the compose network (expose only)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "expose")
    error_message = "nginx_letsencrypt mode must expose terrateam:8080 internally (not host-publish it)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "--email ops@example.com")
    error_message = "certbot must register with the supplied acme_email"
  }
}

run "nginx_mode_without_acme_email_registers_unattended" {
  command = plan

  variables {
    ingress_mode      = "nginx_letsencrypt"
    eip_allocation_id = "eipalloc-0123456789abcdef0"
    # acme_email omitted (optional)
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
    condition     = strcontains(aws_instance.this.user_data, "--register-unsafely-without-email")
    error_message = "certbot must register without email when acme_email is omitted"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "--email ")
    error_message = "certbot must not pass an empty --email when acme_email is omitted"
  }
}

run "nginx_mode_renders_nginx_conf" {
  command = plan

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
    condition     = strcontains(aws_instance.this.user_data, "location /.well-known/acme-challenge/")
    error_message = "nginx.conf must serve the ACME HTTP-01 challenge from the webroot on :80"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "return 301 https://$host$request_uri")
    error_message = "nginx.conf must 301-redirect plain HTTP to HTTPS"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "proxy_pass http://terrateam:8080")
    error_message = "nginx.conf must reverse-proxy to terrateam:8080 over the compose network"
  }

  assert {
    condition = alltrue([
      for h in ["Host $host", "X-Real-IP $remote_addr", "X-Forwarded-For $proxy_add_x_forwarded_for", "X-Forwarded-Proto $scheme"] :
      strcontains(aws_instance.this.user_data, h)
    ])
    error_message = "nginx.conf must forward Host, X-Real-IP, X-Forwarded-For, and X-Forwarded-Proto to terrateam"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "ssl_protocols TLSv1.2 TLSv1.3")
    error_message = "nginx.conf must restrict TLS to 1.2 and 1.3"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/etc/letsencrypt/live/terrateam.example.com/fullchain.pem")
    error_message = "nginx.conf must reference the Let's Encrypt live cert path for the hostname"
  }
}

run "nginx_mode_bootstraps_selfsigned_cert" {
  command = plan

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
    condition     = strcontains(aws_instance.this.user_data, "openssl req -x509")
    error_message = "nginx_letsencrypt must generate a self-signed placeholder so nginx starts before first issuance"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/opt/terrateam/letsencrypt/live/terrateam.example.com")
    error_message = "self-signed placeholder must be written to the host cert path nginx mounts"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/opt/terrateam/acme-webroot")
    error_message = "nginx_letsencrypt must create the shared ACME webroot directory"
  }
}

run "tunnel_mode_has_no_nginx_artifacts" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "/opt/terrateam/nginx.conf")
    error_message = "cloudflare_tunnel mode must not write an nginx.conf"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "proxy_pass http://terrateam:8080")
    error_message = "cloudflare_tunnel mode must not render an nginx reverse-proxy config"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "openssl req -x509")
    error_message = "cloudflare_tunnel mode must not generate a self-signed bootstrap cert"
  }
}

run "nginx_mode_installs_cert_renew_timer" {
  command = plan

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
    condition     = strcontains(aws_instance.this.user_data, "/etc/systemd/system/terrateam-cert-renew.timer")
    error_message = "nginx_letsencrypt must install a cert-renew systemd timer (cert expiry has no event source, unlike SSM param changes)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/etc/systemd/system/terrateam-cert-renew.service")
    error_message = "nginx_letsencrypt must install the cert-renew service the timer triggers"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "certbot renew")
    error_message = "cert-renew must run 'certbot renew'"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "nginx -s reload")
    error_message = "cert-renew must reload nginx so renewed (and first-issued) certs are picked up"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "OnUnitActiveSec=12h")
    error_message = "cert-renew timer must fire twice daily"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "systemctl enable --now terrateam-cert-renew.timer")
    error_message = "cert-renew timer must be enabled at boot"
  }
}

run "tunnel_mode_has_no_cert_renew_timer" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "terrateam-cert-renew")
    error_message = "cloudflare_tunnel mode must not install a cert-renew timer (no certs to renew)"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "certbot renew")
    error_message = "cloudflare_tunnel mode must not run certbot renew"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "nginx-logs")
    error_message = "cloudflare_tunnel mode must not collect nginx logs"
  }
}

run "nginx_mode_ships_proxy_logs_to_cloudwatch" {
  command = plan

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
    condition     = strcontains(aws_instance.this.user_data, "/opt/terrateam/nginx-logs/access.log")
    error_message = "CW agent must collect nginx access logs in nginx_letsencrypt mode"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/opt/terrateam/nginx-logs/error.log")
    error_message = "CW agent must collect nginx error logs in nginx_letsencrypt mode"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/var/log/terrateam-cert-renew.log")
    error_message = "CW agent must collect certbot renewal output in nginx_letsencrypt mode"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "\"${var.log_group_prefix}/nginx\"")
    error_message = "nginx logs must ship to the ${var.log_group_prefix}/nginx log group (within the IAM scope)"
  }

  # nginx must write logs to a host-mounted dir for the file-based CW agent to read them.
  assert {
    condition     = strcontains(aws_instance.this.user_data, "/opt/terrateam/nginx-logs:/var/log/nginx")
    error_message = "nginx must mount a host log dir so access/error logs land in files the CW agent can ship"
  }
}

run "nginx_mode_user_data_is_valid_cloud_init" {
  command = plan

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
    condition     = startswith(aws_instance.this.user_data, "#cloud-config")
    error_message = "nginx_letsencrypt user-data must still start with #cloud-config"
  }

  assert {
    condition     = can(yamldecode(aws_instance.this.user_data))
    error_message = "nginx_letsencrypt user-data must remain valid cloud-init YAML"
  }
}
