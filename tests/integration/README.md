# Integration tests — modules/terrateam_server

Spins up a real EC2 instance plus dependencies, runs an SSM-driven probe inside the instance that checks both terrat-oss and postgres, then tears everything down.

## What it asserts

- The pinned AMI boots on `t4g.small`.
- `cloud-init status --wait` exits 0 — i.e. cloud-init reached `status=done`, not `error` or `degraded`. This is the gate that catches a bad `packages:` entry, a failing `runcmd`, or a wedged `bootcmd`. On failure the probe dumps `cloud-init status --long` so the SSM command history shows the offending module and stderr.
- Cloud-init runs cleanly: Docker installs, the EBS data volume mounts via the NVMe-by-id path, the five SSM parameters are read, the pinned `terrat-oss` and `cloudflared` images pull, and the `terrateam.service` systemd unit comes up.
- `terrat-oss` is bound on port 8080 (TCP open on localhost — proves the container is live; we don't inspect the HTTP response since placeholder GitHub App credentials don't allow a clean 200).
- `postgres` is accepting connections (`pg_isready` succeeds inside the container — proves the EBS volume mounted, `initdb` ran, and the daemon is listening).

## How the wait works

The probe is an `aws_ssm_association` running `AWS-RunShellScript` inside the instance. Terraform blocks on `wait_for_success_timeout_seconds = 900` until the association reaches `Success`. Success requires the SSM Agent registered (a "fully booted" signal) AND both probe checks above passed. No fixed sleeps in Terraform, no SG ingress to the runner, no `data.http` block to re-evaluate during destroy.

## What it doesn't test

- The Cloudflare Tunnel path. `cloudflared` fails to authenticate against the placeholder token and restarts in a loop; the probe runs against `localhost:8080` on the instance, bypassing the tunnel.
- The actual GitHub App webhook flow. The placeholders aren't real credentials.

## Running

```sh
cd modules/terrateam_server/tests/integration
terraform init
terraform test
```

Requires AWS credentials with permission to create VPC, EC2, EBS, SSM parameter, SSM association, and IAM resources in `us-west-2`. State is local — there's no shared backend. Cost per run is in cents (instance + EBS for under an hour).

## Tuning

- `wait_for_success_timeout_seconds` on `aws_ssm_association.wait_for_terrateam` is 900. The longest leg in practice is the `terrat-oss` image pull on a cold instance; if the test starts flaking on that, bump it.
- The script's inner loop is 120 × 5 s; that's the upper bound for the time between SSM Agent reporting in and both checks (port 8080 + `pg_isready`) passing — i.e. the tail of cloud-init after Docker installs and image pulls finish.
