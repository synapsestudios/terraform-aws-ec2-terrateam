# AWS EC2 Terrateam

Reusable Terraform module for a single-host, self-hosted [Terrateam](https://terrateam.io) instance — an EC2 in a public subnet running the Terrateam `docker-compose` reference stack (`terrat-oss` + `postgres:14` + an ingress proxy) with Postgres data on a caller-attached EBS volume.

The module is opinionated on security posture and operational model: IMDSv2 is required, the root volume is encrypted, the IAM role is scoped to just the SSM parameters the caller passes in, and the host enrolls in SSM Session Manager so operators don't need SSH. Secrets land on disk via an idempotent render unit that re-runs on every Parameter Store change via EventBridge — no polling, no manual rotation.

How traffic reaches `terrat-oss` is selectable via [`ingress_mode`](#ingress-modes). The default, `cloudflare_tunnel`, keeps the module's headline posture: the security group has **no ingress** and the host is reachable only via the caller's Cloudflare Tunnel. The alternative, `nginx_letsencrypt`, removes the Cloudflare dependency by opening 80/443 and terminating TLS on the host with nginx + Let's Encrypt.

## Usage

```hcl
module "terrateam" {
  source = "git::https://github.com/synapsestudios/terraform-aws-ec2-terrateam.git?ref=v0.1.0"

  namespace      = "acme-prod"
  hostname       = "terrateam.acme.example"
  github_app_url = "https://github.com/apps/terrateam-acme"

  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]

  # Pin AMI explicitly — AL2023 republishes frequently and the module
  # sets lifecycle { ignore_changes = [ami] } so bumping is opt-in.
  ami_id = "ami-023a34a1153befb51"

  # Caller-owned: survives instance replacement, snapshot via DLM.
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

`ingress_mode` selects how inbound HTTPS reaches `terrat-oss`. It defaults to `cloudflare_tunnel`, so **existing deployers are unaffected**.

| | `cloudflare_tunnel` (default) | `nginx_letsencrypt` |
|---|---|---|
| Security group | **No ingress** — outbound tunnel only | Opens **80 + 443** to `0.0.0.0/0` |
| Public edge | Cloudflare (DDoS shielding + WAF) | **None** — host is directly internet-exposed |
| TLS | Terminated at Cloudflare's edge | nginx on the host, **Let's Encrypt** cert (certbot, HTTP-01) |
| Ingress container(s) | `cloudflared` | `nginx` + `certbot` |
| Caller must provide | Cloudflare Tunnel resource + connector token (SSM) | A caller-owned **Elastic IP** (`eip_allocation_id`) + a DNS **A record** pointing at it |
| `terrat-oss` exposure | Published to `127.0.0.1:8080` for cloudflared | Internal-only (`expose`); only nginx reaches it |

### ⚠️ Security trade-off (opt-in)

The "no ingress — reachable only via Cloudflare Tunnel" posture is a deliberate headline feature. **`nginx_letsencrypt` abandons it**: the host is directly exposed on 80/443 and loses Cloudflare's edge DDoS shielding and WAF. Choose it only when you can't/won't depend on Cloudflare and accept terminating TLS on a directly-exposed host. The default stays `cloudflare_tunnel`.

### Using `nginx_letsencrypt`

```hcl
module "terrateam" {
  source = "git::https://github.com/synapsestudios/terraform-aws-ec2-terrateam.git?ref=v0.2.0"

  ingress_mode = "nginx_letsencrypt"

  namespace      = "acme-prod"
  hostname       = "terrateam.acme.example" # must resolve (A record) to the EIP below
  github_app_url = "https://github.com/apps/terrateam-acme"

  vpc_id           = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnets[0]
  ami_id           = "ami-023a34a1153befb51"
  data_volume_id   = aws_ebs_volume.terrateam_data.id

  # Caller-owned, so the address survives instance replacement (the DNS A record
  # and Let's Encrypt issuance both depend on a stable IP).
  eip_allocation_id = aws_eip.terrateam.allocation_id
  acme_email        = "ops@acme.example" # optional; Let's Encrypt expiry notices

  # No tunnel token in this mode — drop it from both lists.
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

The DNS A record must resolve to the EIP **before** first boot — certbot's HTTP-01 challenge needs the hostname to reach the host on port 80. nginx starts immediately on a self-signed placeholder so it never blocks on issuance; the certbot sidecar then obtains the real cert, and a host `terrateam-cert-renew.timer` (twice daily) renews it and reloads nginx. If first-boot issuance fails (e.g. DNS not yet propagated), nginx keeps serving the placeholder and the cert is reissued on the next instance replacement.

> **Certificate persistence:** Let's Encrypt certs live on the instance's root volume and do **not** survive instance replacement — a fresh cert is issued on replacement (well within Let's Encrypt rate limits). This is intentional for v1.

> **Renewal uses a systemd timer**, unlike secret rotation (which is EventBridge-driven). Certificate expiry has no event source to react to, so a twice-daily timer is the right tool here — it is not a regression of the module's "no polling" stance.

## What the module owns

- The `aws_instance`, with caller-supplied AMI and `lifecycle { ignore_changes = [ami] }` so AL2023 AMI rotations don't churn the host.
- A security group: egress anywhere, and ingress per `ingress_mode` — **no ingress** in `cloudflare_tunnel` mode (reachable only via the caller's tunnel), or **80 + 443** open in `nginx_letsencrypt` mode.
- In `nginx_letsencrypt` mode, the `aws_eip_association` binding the caller's Elastic IP to the instance (the module does not create the EIP — the caller owns it).
- An IAM role + instance profile scoped to: read the SSM parameters the caller passes in (`var.ssm_parameter_arns`), write to `${var.log_group_prefix}/*` log groups under the caller's account, and operate as an SSM-managed instance for SSH-less ops.
- The cloud-init user-data: installs Docker + compose plugin + CloudWatch Agent, mounts the data EBS volume by **NVMe serial** (reliable on Nitro), drops a render-secrets script + systemd unit that fetches SSM SecureStrings into a root-only `.env`/PEM, writes a pinned `docker-compose.yml`, and runs the stack as a `systemd` unit ordered after the render unit. In `nginx_letsencrypt` mode it also writes the templated `nginx.conf`, a self-signed bootstrap cert, and the `terrateam-cert-renew` timer.
- The `aws_volume_attachment` for the caller's data EBS volume.
- **Pinned default versions** for the application containers (`terrateam_image_tag`, and `cloudflared_image_tag` / `nginx_image_tag` + `certbot_image_tag` depending on mode). These are inputs with sensible defaults so the AMI-pinning rationale isn't undermined by silently rolling app code on every restart.
- **Secret-rotation reconciler** (`rotation.tf`): an EventBridge rule on `aws.ssm` / `Parameter Store Change` for the seven `${var.log_group_prefix}/*` parameters, an IAM role for EventBridge → `ssm:SendCommand` scoped to this instance + `AWS-RunShellScript` only, and a target that runs `systemctl start terrateam-render-secrets.service` on the host. Boot- and rotation-time render output land in CW log group `${var.log_group_prefix}/render-secrets`.

## What the caller owns

- The data EBS volume (so it survives instance replacement).
- The DLM lifecycle policy that snapshots the data volume.
- **`cloudflare_tunnel` mode:** the Cloudflare Tunnel resource that produces the connector token, and the DNS record that points at the tunnel.
- **`nginx_letsencrypt` mode:** the Elastic IP (`aws_eip`, passed as `eip_allocation_id`) and the DNS **A record** pointing at it.
- The SSM parameters (the module only sees ARN references and parameter names — never the values): seven in `cloudflare_tunnel` mode, or six in `nginx_letsencrypt` mode (no tunnel token).

## Inputs

See `variables.tf`. The most consequential ones:

- `ingress_mode` — `cloudflare_tunnel` (default) or `nginx_letsencrypt`. See [Ingress modes](#ingress-modes).
- `eip_allocation_id` — caller-owned Elastic IP allocation. **Required in `nginx_letsencrypt` mode**, unused otherwise.
- `acme_email` — optional Let's Encrypt registration email (`nginx_letsencrypt` mode); omit to register without one.
- `data_volume_id` — must already exist; module attaches it and discovers it via NVMe serial.
- `ssm_parameter_arns` — the IAM role is scoped to exactly these.
- `user_data_inputs` — names of the SSM parameters the boot script reads (`tunnel_token_param_name` is optional and omitted in `nginx_letsencrypt` mode).
- `terrateam_image_tag` / `cloudflared_image_tag` / `nginx_image_tag` / `certbot_image_tag` — defaults are the versions verified by this module; bumping is opt-in.
- `log_group_prefix` — defaults to `/terrateam`; constrains the IAM `logs:*` scope.

## Outputs

`instance_id`, `public_ip`, `security_group_id`, `iam_role_arn`, `iam_role_name`.

## Running tests

Tests follow the [Synapse Terraform Testing guide](https://docs.synapsestudios.com/implementation/infrastructure/terraform-testing) and use the native `terraform test` framework. The `-test-directory` flag is required on `init` so Terraform discovers modules referenced from test files in non-default directories.

| Lane | Path | Cost | When it runs |
|---|---|---|---|
| Unit | `tests/unit/` | Free — `mock_provider` | Locally, and (once CI is wired) on every PR |
| Integration | `tests/integration/` | Real AWS — EC2 + EBS for ~15 min | Locally, or via manual dispatch in CI |

```bash
# Unit — no AWS credentials required
terraform init -test-directory=tests/unit
terraform test -test-directory=tests/unit

# Integration — requires AWS credentials in us-west-2
terraform init -test-directory=tests/integration
terraform test -test-directory=tests/integration
```

The integration lane provisions a minimal VPC + EBS + SSM parameters, boots the module's pinned AMI, and runs an SSM-driven probe inside the instance that checks `cloud-init status`, `terrat-oss` on `localhost:8080`, and `pg_isready` in the postgres container. See `tests/integration/README.md` for the gate details.
