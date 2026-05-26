# AWS EC2 Terrateam

Reusable Terraform module for a single-host, self-hosted [Terrateam](https://terrateam.io) instance — an EC2 in a public subnet running the Terrateam `docker-compose` reference stack (`terrat-oss` + `postgres:14` + `cloudflared`) with Postgres data on a caller-attached EBS volume.

The module is opinionated on security posture and operational model: the security group has **no ingress** (the host is reachable only via the caller's Cloudflare Tunnel), IMDSv2 is required, the root volume is encrypted, the IAM role is scoped to just the SSM parameters the caller passes in, and the host enrolls in SSM Session Manager so operators don't need SSH. Secrets land on disk via an idempotent render unit that re-runs on every Parameter Store change via EventBridge — no polling, no manual rotation.

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

## What the module owns

- The `aws_instance`, with caller-supplied AMI and `lifecycle { ignore_changes = [ami] }` so AL2023 AMI rotations don't churn the host.
- A security group that egresses anywhere and **does not accept ingress** — Terrateam is reachable only via the caller's Cloudflare Tunnel running on the host.
- An IAM role + instance profile scoped to: read the SSM parameters the caller passes in (`var.ssm_parameter_arns`), write to `${var.log_group_prefix}/*` log groups under the caller's account, and operate as an SSM-managed instance for SSH-less ops.
- The cloud-init user-data: installs Docker + compose plugin + CloudWatch Agent, mounts the data EBS volume by **NVMe serial** (reliable on Nitro), drops a render-secrets script + systemd unit that fetches SSM SecureStrings into a root-only `.env`/PEM, writes a pinned `docker-compose.yml`, and runs the stack as a `systemd` unit ordered after the render unit.
- The `aws_volume_attachment` for the caller's data EBS volume.
- **Pinned default versions** for the application containers (`terrateam_image_tag`, `cloudflared_image_tag`). These are inputs with sensible defaults so the AMI-pinning rationale isn't undermined by silently rolling app code on every restart.
- **Secret-rotation reconciler** (`rotation.tf`): an EventBridge rule on `aws.ssm` / `Parameter Store Change` for the seven `${var.log_group_prefix}/*` parameters, an IAM role for EventBridge → `ssm:SendCommand` scoped to this instance + `AWS-RunShellScript` only, and a target that runs `systemctl start terrateam-render-secrets.service` on the host. Boot- and rotation-time render output land in CW log group `${var.log_group_prefix}/render-secrets`.

## What the caller owns

- The data EBS volume (so it survives instance replacement).
- The DLM lifecycle policy that snapshots the data volume.
- The Cloudflare Tunnel resource that produces the connector token.
- The DNS record that points at the tunnel.
- All seven SSM parameters (the module only sees ARN references and parameter names — it never sees the values).

## Inputs

See `variables.tf`. The most consequential ones:

- `data_volume_id` — must already exist; module attaches it and discovers it via NVMe serial.
- `ssm_parameter_arns` — the IAM role is scoped to exactly these.
- `user_data_inputs` — names of the seven SSM parameters the boot script reads.
- `terrateam_image_tag` / `cloudflared_image_tag` — defaults are the latest version verified by this module; bumping is opt-in.
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
