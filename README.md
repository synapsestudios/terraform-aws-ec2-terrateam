# AWS EC2 Terrateam

Terraform module for a self-hosted [Terrateam](https://terrateam.io) instance on one EC2 host. The host sits in a public subnet and runs the Terrateam `docker-compose` reference stack: `terrat-oss`, `postgres:14`, and an ingress proxy. Postgres data lives on an EBS volume the caller owns and attaches.

The module makes several choices for you. IMDSv2 is required. The root volume is encrypted. The IAM role can read only the SSM parameters the caller passes in. The host enrolls in SSM Session Manager, so nobody needs SSH. Secrets reach disk through a render unit that runs at boot and again whenever a Parameter Store value changes, which EventBridge triggers. Nothing polls, and rotation needs no manual step.

[`ingress_mode`](#ingress-modes) selects how traffic reaches `terrat-oss`. The default, `cloudflare_tunnel`, leaves the security group with no ingress rules at all, and the host is reachable only through the caller's Cloudflare Tunnel. The alternative, `nginx_letsencrypt`, drops the Cloudflare dependency. It opens ports 80 and 443 and terminates TLS on the host with nginx and a Let's Encrypt certificate.

## Usage

```hcl
module "terrateam" {
  source = "git::https://github.com/synapsestudios/terraform-aws-ec2-terrateam.git?ref=v0.1.0"

  namespace      = "acme-prod"
  hostname       = "terrateam.acme.example"
  github_app_url = "https://github.com/apps/terrateam-acme"

  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]

  # Pin the AMI. AL2023 republishes often, and the module sets
  # lifecycle { ignore_changes = [ami] }, so bumping is opt-in.
  ami_id = "ami-023a34a1153befb51"

  # Caller-owned. Survives instance replacement; snapshot it with DLM.
  data_volume_id = aws_ebs_volume.terrateam_data.id

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

  tags = { ApplicationName = "terrateam" }
}
```

## Ingress modes

`ingress_mode` selects how inbound HTTPS reaches `terrat-oss`. The default is `cloudflare_tunnel`, so existing deployments keep working without changes.

| | `cloudflare_tunnel` (default) | `nginx_letsencrypt` |
|---|---|---|
| Security group | No ingress rules. Only the outbound tunnel. | Opens 80 and 443 to `0.0.0.0/0` |
| Public edge | Cloudflare, with its DDoS protection and WAF | None. The host faces the internet directly. |
| TLS | Terminated at Cloudflare's edge | nginx on the host, with a Let's Encrypt certificate from certbot (HTTP-01) |
| Ingress containers | `cloudflared` | `nginx` and `certbot` |
| Caller provides | A Cloudflare Tunnel and its connector token in SSM | An Elastic IP (`eip_allocation_id`), plus either a DNS A record pointing at it or a Route 53 hosted zone (`route53_zone_id`) for the module to create one in |
| `terrat-oss` exposure | Published on `127.0.0.1:8080` for cloudflared | Compose network only (`expose`). Only nginx can reach it. |

### Security trade-off

A host with no inbound security-group rules is the point of the default mode. `nginx_letsencrypt` gives that up. The host answers on 80 and 443 from anywhere and loses Cloudflare's DDoS protection and WAF. Pick it only when you cannot or will not depend on Cloudflare and are willing to terminate TLS on an internet-facing host. The default stays `cloudflare_tunnel`.

### Switching modes

Changing `ingress_mode` on a running deployment recreates the instance. The module sets `user_data_replace_on_change = true` because cloud-init runs only at first boot. A plain stop and start would leave the host on the old ingress stack. Durable state survives the recreate. Postgres data is on the caller's EBS volume, and in `nginx_letsencrypt` mode the caller's Elastic IP and DNS A record stay put, so the public address does not change. Switching to `nginx_letsencrypt` means adding `eip_allocation_id` and dropping the tunnel-token parameter. Switching back means the reverse, and also removes the module's Route 53 record if `route53_zone_id` was set. Image-tag bumps work the same way and recreate the host.

Adding `route53_zone_id` to a deployment that already has a hand-made A record for the hostname does not recreate anything. The module creates its record with `allow_overwrite = false`, so the apply fails while the old record exists. Import the existing record into `module.<name>.aws_route53_record.this[0]` with `terraform import`, or delete it first. Removing `route53_zone_id` later deletes the module's record and touches nothing else.

### Using `nginx_letsencrypt`

```hcl
module "terrateam" {
  source = "git::https://github.com/synapsestudios/terraform-aws-ec2-terrateam.git?ref=v0.2.0"

  ingress_mode = "nginx_letsencrypt"

  namespace      = "acme-prod"
  hostname       = "terrateam.acme.example" # the A record for this name points at the EIP below
  github_app_url = "https://github.com/apps/terrateam-acme"

  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]
  ami_id           = "ami-023a34a1153befb51"
  data_volume_id   = aws_ebs_volume.terrateam_data.id

  # Caller-owned, so the address survives instance replacement. The DNS A record
  # and Let's Encrypt issuance both depend on a stable IP.
  eip_allocation_id = aws_eip.terrateam.allocation_id
  acme_email        = "ops@acme.example" # optional, for Let's Encrypt expiry notices

  # Optional. Hand the module a same-account hosted zone and it creates the
  # A record for hostname. Omit it to manage the record yourself.
  route53_zone_id = aws_route53_zone.acme.zone_id

  # No tunnel token in this mode. Drop it from both lists.
  ssm_parameter_arns = [
    aws_ssm_parameter.github_app_id.arn,
    aws_ssm_parameter.github_app_pem.arn,
    aws_ssm_parameter.github_app_client_id.arn,
    aws_ssm_parameter.github_app_client_secret.arn,
    aws_ssm_parameter.webhook_secret.arn,
    aws_ssm_parameter.postgres_password.arn,
  ]

  user_data_inputs = {
    github_app_id_param            = aws_ssm_parameter.github_app_id.name
    github_app_pem_param           = aws_ssm_parameter.github_app_pem.name
    github_app_client_id_param     = aws_ssm_parameter.github_app_client_id.name
    github_app_client_secret_param = aws_ssm_parameter.github_app_client_secret.name
    webhook_secret_param           = aws_ssm_parameter.webhook_secret.name
    postgres_password_param        = aws_ssm_parameter.postgres_password.name
  }

  tags = { ApplicationName = "terrateam" }
}
```

The hostname must resolve to the Elastic IP, because certbot's HTTP-01 challenge needs it to reach port 80 on the host. With `route53_zone_id` set, the module creates that A record with a 60-second TTL, pointing at the EIP. The record has no dependency on the instance, so Terraform creates it at the start of the apply, and it is usually live well before cloud-init reaches certbot. Without it, create the record yourself before first boot.

nginx starts right away on a self-signed placeholder certificate, so it never waits on issuance. The certbot sidecar then requests the real certificate. A host systemd timer, `terrateam-cert-renew.timer`, runs 5 minutes after boot and then twice a day. When a certificate exists, it renews it and reloads nginx. When first issuance failed, for example because DNS had not propagated yet, nginx keeps serving the placeholder and the timer retries issuance until a certificate exists.

Certificates live on the instance's root volume and do not survive instance replacement. A replacement requests a fresh certificate. Let's Encrypt allows five certificates per exact hostname set every seven days, so this only matters if you replace the instance more often than that. That is a v1 decision.

Renewal is the one scheduled job on the host. Secret rotation reacts to EventBridge events, but certificate expiry has no event source, so a twice-daily systemd timer covers it.

## What the module owns

- The `aws_instance`, with a caller-supplied AMI and `lifecycle { ignore_changes = [ami] }`, so AL2023 AMI rotations do not churn the host.
- A security group. Egress is open. Ingress depends on `ingress_mode`: none in `cloudflare_tunnel` mode, or 80 and 443 in `nginx_letsencrypt` mode.
- In `nginx_letsencrypt` mode, the `aws_eip_association` that binds the caller's Elastic IP to the instance. The caller creates and owns the EIP itself. When `route53_zone_id` is set, the module also owns the Route 53 A record for `hostname` pointing at that EIP.
- An IAM role and instance profile. The role can read the SSM parameters in `ssm_parameter_arns`, describe EC2 volumes and instances, write to log groups under `log_group_prefix` in the caller's account, and act as an SSM-managed instance for SSH-less operations.
- The cloud-init user data. It installs Docker, the compose plugin, and the CloudWatch agent. It mounts the data volume by NVMe serial, which is stable on Nitro instances. It writes a render-secrets script and systemd unit that fetch the SSM SecureStrings into a root-only `.env` file and PEM file. It writes a pinned `docker-compose.yml` and runs the stack as a systemd unit ordered after the render unit. In `nginx_letsencrypt` mode it also writes the rendered `nginx.conf`, a self-signed bootstrap certificate, and the `terrateam-cert-renew` timer.
- The `aws_volume_attachment` for the caller's data volume.
- Pinned default image tags for the containers: `terrateam_image_tag`, plus `cloudflared_image_tag` or `nginx_image_tag` and `certbot_image_tag` depending on mode. Each is an input with a pinned default, so a restart never silently pulls new application code. Pinning the AMI would mean little otherwise.
- The secret-rotation reconciler in `rotation.tf`. An EventBridge rule matches `Parameter Store Change` events for the parameter names in `user_data_inputs`. An IAM role lets EventBridge call `ssm:SendCommand`, limited to this instance and the `AWS-RunShellScript` document. The target runs `systemctl start terrateam-render-secrets.service` on the host. The render script compares the fetched values with what is on disk and restarts the stack only when something changed.
- The CloudWatch log group `${log_group_prefix}/render-secrets`, with 365-day retention. Boot-time and rotation-time render output lands there. In `nginx_letsencrypt` mode the CloudWatch agent also ships nginx access and error logs to `${log_group_prefix}/nginx` and renewal output to `${log_group_prefix}/cert-renew`.

## What the caller owns

- The data EBS volume, so it survives instance replacement.
- The DLM lifecycle policy that snapshots the data volume.
- In `cloudflare_tunnel` mode, the Cloudflare Tunnel that produces the connector token, and the DNS record that points at the tunnel.
- In `nginx_letsencrypt` mode, the Elastic IP passed as `eip_allocation_id`. The caller also owns the hosted zone when `route53_zone_id` is set, and otherwise the DNS A record pointing at the EIP.
- The SSM parameters. The module sees only ARNs and names, never values. There are seven in `cloudflare_tunnel` mode and six in `nginx_letsencrypt` mode, which has no tunnel token.

## Inputs

See `variables.tf` for the full list. The ones that matter most:

- `ingress_mode`: `cloudflare_tunnel` (default) or `nginx_letsencrypt`. See [Ingress modes](#ingress-modes).
- `eip_allocation_id`: a caller-owned Elastic IP allocation. Required in `nginx_letsencrypt` mode and unused otherwise.
- `route53_zone_id`: optional same-account Route 53 hosted zone, `nginx_letsencrypt` mode only. When set, the module creates the A record for `hostname`. A zone in another account would need a second provider and is unsupported, so keep owning the record yourself in that case.
- `acme_email`: optional Let's Encrypt registration email for `nginx_letsencrypt` mode. Omit it to register without one.
- `data_volume_id`: must already exist. The module attaches it and finds it on the host by NVMe serial.
- `ssm_parameter_arns`: the IAM role can read exactly these.
- `user_data_inputs`: names of the SSM parameters the boot script reads. `tunnel_token_param_name` is optional and omitted in `nginx_letsencrypt` mode.
- `terrateam_image_tag`, `cloudflared_image_tag`, `nginx_image_tag`, `certbot_image_tag`: defaults are the versions this module was tested with. Bumping is opt-in.
- `log_group_prefix`: defaults to `/terrateam` and bounds the IAM `logs:*` permissions.

## Outputs

`instance_id`, `public_ip`, `security_group_id`, `iam_role_arn`, `iam_role_name`, and `route53_record_fqdn`, which is null unless the module manages the record.

In `cloudflare_tunnel` mode `public_ip` is an egress address only. In `nginx_letsencrypt` mode the caller's Elastic IP is the inbound address, so the DNS A record, whether yours or the module's, points at the EIP. `public_ip` is the address the instance received at launch.

## Running tests

Tests follow the [Synapse Terraform Testing guide](https://docs.synapsestudios.com/implementation/infrastructure/terraform-testing) and use the native `terraform test` framework.

| Lane | Path | Cost | When it runs |
|---|---|---|---|
| Unit | `tests/unit/` | Free. Uses `mock_provider`. | Locally, and in CI on every pull request. |
| Integration | `tests/integration/` | Real AWS. An EC2 instance and EBS volume per test, for roughly 15 minutes each. | Locally, or by manual dispatch in CI. |

The unit lane tests this repo's root module, so pass `-test-directory` on both `init` and `test` to make Terraform find the test files and any modules they reference. The integration suite is its own root module under `tests/integration`, with a VPC, an EBS volume, and SSM parameters wrapped around the module under test, so run it from that directory.

```bash
# Unit. No AWS credentials needed.
terraform init -test-directory=tests/unit
terraform test -test-directory=tests/unit

# Integration. Needs AWS credentials in us-west-2.
cd tests/integration
terraform init
terraform test
```

CI runs `terraform fmt`, `terraform validate`, and the unit lane on every pull request, once with the committed provider lock, once with the lowest AWS provider version the module allows, and once with the newest. A weekly scheduled run repeats that against the newest provider. The integration lane runs only on manual dispatch.

The integration lane has two tests. The tunnel-mode test builds a small VPC, an EBS volume, and placeholder SSM parameters, boots the harness's pinned AMI, and runs a probe over SSM inside the instance. The probe checks that cloud-init finished, that `terrat-oss` listens on `localhost:8080`, and that `pg_isready` succeeds in the postgres container. The nginx-mode test adds a real Elastic IP, checks the proxy chain from inside the instance, and curls the Elastic IP from the machine running Terraform to prove the security group and EIP work from outside. Neither test exercises real Let's Encrypt issuance, the module-managed Route 53 record, or the Cloudflare Tunnel itself. See `tests/integration/README.md` for the gate details.
