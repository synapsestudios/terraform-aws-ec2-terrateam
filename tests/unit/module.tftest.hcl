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
  # Pin the region the EventBridge target's AWS-RunShellScript ARN gets built
  # from; otherwise the mock generates a random string and AWS ARN validation
  # fails the plan (hashicorp/terraform-provider-aws#42834).
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

run "apply_smoke" {
  command = apply

  module {
    source = "../../"
  }
}

run "instance_name_follows_namespace_convention" {
  command = plan

  assert {
    condition     = aws_instance.this.tags["Name"] == "acme-prod-terrateam"
    error_message = "Name tag should be namespace-name"
  }

  assert {
    condition     = aws_instance.this.tags["Module"] == "terraform-aws-ec2-terrateam"
    error_message = "Module tag should identify this module"
  }

  assert {
    condition     = aws_instance.this.tags["ModuleVersion"] == "local"
    error_message = "ModuleVersion should be 'local' for in-repo module"
  }
}

run "input_tags_pass_through_and_merge" {
  command = plan

  variables {
    tags = {
      Project = "acme.example"
    }
  }

  assert {
    condition     = aws_instance.this.tags["Project"] == "acme.example"
    error_message = "Caller-supplied tags should pass through onto module-created resources"
  }
}

run "imdsv2_required" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "Module must enforce IMDSv2"
  }
}

run "root_volume_is_encrypted_gp3" {
  command = plan

  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true
    error_message = "Root volume must be encrypted"
  }

  assert {
    condition     = aws_instance.this.root_block_device[0].volume_type == "gp3"
    error_message = "Root volume should be gp3"
  }
}

run "no_ingress_rules_traffic_via_tunnel" {
  # apply (not plan): aws_security_group.ingress is a computed set that the
  # provider leaves unknown at plan time, so the assertion can't evaluate
  # under command = plan even though we use mock_provider.
  command = apply

  assert {
    condition     = length(aws_security_group.this.ingress) == 0
    error_message = "Security group must not allow ingress; ingress comes via Cloudflare Tunnel outbound"
  }
}

run "user_data_references_all_ssm_params" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/terrateam/tunnel-token")
    error_message = "user-data should reference the tunnel token SSM parameter"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/terrateam/github-app-pem")
    error_message = "user-data should reference the github app pem SSM parameter"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/terrateam/postgres-password")
    error_message = "user-data should reference the postgres password SSM parameter"
  }
}

run "user_data_pins_container_versions_by_default" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "terrat-oss:latest")
    error_message = "terrat-oss image must be pinned to a version, not :latest"
  }

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "cloudflared:latest")
    error_message = "cloudflared image must be pinned to a version, not :latest"
  }
}

run "user_data_discovers_data_volume_by_nvme_serial" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_")
    error_message = "user-data must look up the data volume by NVMe serial, not by /dev/xvdf"
  }
}

run "iam_role_logs_scope_is_constrained_to_terrateam_log_groups" {
  command = plan

  assert {
    condition = strcontains(
      aws_iam_role_policy.this.policy,
      ":log-group:/terrateam/*"
    )
    error_message = "IAM policy must scope logs:* to /terrateam/* log groups"
  }
}

run "iam_role_grants_ssm_read_only_on_supplied_params" {
  command = plan

  assert {
    condition = strcontains(
      aws_iam_role_policy.this.policy,
      "arn:aws:ssm:us-west-2:111122223333:parameter/terrateam/github-app-pem"
    )
    error_message = "IAM policy should grant ssm:GetParameter on the supplied parameter ARNs"
  }
}

run "ami_set_from_input" {
  command = plan

  assert {
    condition     = aws_instance.this.ami == "ami-023a34a1153befb51"
    error_message = "Instance should use the provided ami_id"
  }
}

run "user_data_is_valid_cloud_init_config" {
  command = plan

  assert {
    condition     = startswith(aws_instance.this.user_data, "#cloud-config")
    error_message = "user-data must start with #cloud-config so cloud-init treats it as YAML config and not a shell script"
  }

  assert {
    condition     = can(yamldecode(aws_instance.this.user_data))
    error_message = "user-data must be valid YAML for cloud-init to consume"
  }

  assert {
    condition = alltrue([
      for k in ["packages", "bootcmd", "fs_setup", "mounts", "write_files", "runcmd"] :
      contains(keys(yamldecode(aws_instance.this.user_data)), k)
    ])
    error_message = "cloud-init config must define packages, bootcmd, fs_setup, mounts, write_files, and runcmd modules"
  }

  assert {
    condition = alltrue([
      for entry in yamldecode(aws_instance.this.user_data).mounts :
      length(entry) == 6
    ])
    error_message = "every mounts entry must be a 6-field list [fs_spec, fs_file, fs_vfstype, fs_mntops, fs_freq, fs_passno] per cloud-init schema"
  }

  assert {
    condition = alltrue([
      for f in yamldecode(aws_instance.this.user_data).write_files :
      can(f.path) && can(f.content)
    ])
    error_message = "every write_files entry must declare at least path and content"
  }
}

run "user_data_does_not_dnf_install_awscli_already_preinstalled_on_al2023" {
  command = plan

  assert {
    condition     = !contains(yamldecode(aws_instance.this.user_data).packages, "awscli")
    error_message = "AL2023 ships AWS CLI v2 preinstalled (package awscli-2); the bare 'awscli' alias resolves to the legacy v1 Python package on Amazon Linux, so listing it here either fails the dnf step or installs v1 next to the preinstalled v2"
  }
}

run "user_data_installs_compose_plugin_from_binary_not_dnf" {
  command = plan

  assert {
    condition     = !contains(yamldecode(aws_instance.this.user_data).packages, "docker-compose-plugin")
    error_message = "docker-compose-plugin is a Debian package name; AL2023 does not provide it via dnf, so it must not appear in the packages list"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/usr/local/lib/docker/cli-plugins/docker-compose")
    error_message = "user-data must drop the compose plugin into /usr/local/lib/docker/cli-plugins/docker-compose"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "github.com/docker/compose/releases/download/v")
    error_message = "user-data must download a pinned compose plugin release from github.com/docker/compose/releases"
  }
}

run "user_data_installs_render_secrets_script" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/usr/local/sbin/terrateam-render-secrets.sh")
    error_message = "user-data must install the render-secrets script at /usr/local/sbin/terrateam-render-secrets.sh — single renderer triggered on boot and on rotation"
  }
}

run "render_script_fetches_all_ssm_params_in_one_call" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "aws ssm get-parameters")
    error_message = "render script must use ssm get-parameters (plural, single API call), not get-parameter per-name"
  }

  assert {
    condition = alltrue([
      for n in [
        "/terrateam/tunnel-token",
        "/terrateam/github-app-id",
        "/terrateam/github-app-pem",
        "/terrateam/github-app-client-id",
        "/terrateam/github-app-client-secret",
        "/terrateam/github-webhook-secret",
        "/terrateam/postgres-password",
      ] : strcontains(aws_instance.this.user_data, n)
    ])
    error_message = "render script must reference every SSM parameter name"
  }
}

run "render_script_atomically_swaps_only_on_change" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "mktemp")
    error_message = "render script must build new content in a tempfile before swapping"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "cmp -s")
    error_message = "render script must use cmp -s to detect changes before swapping (idempotency: no restart when SSM values unchanged)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "systemctl restart --no-block terrateam.service")
    error_message = "render script must restart terrateam.service with --no-block; a synchronous restart deadlocks against Requires=terrateam-render-secrets.service"
  }
}

run "render_secrets_systemd_unit_present" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/etc/systemd/system/terrateam-render-secrets.service")
    error_message = "user-data must install the render-secrets systemd unit"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "Type=oneshot")
    error_message = "render-secrets unit must be Type=oneshot — runs the script once per invocation, no daemon"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "ExecStart=/usr/local/sbin/terrateam-render-secrets.sh")
    error_message = "render-secrets unit's ExecStart must invoke the render script"
  }
}

run "terrateam_service_requires_render_secrets_first" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "Requires=docker.service terrateam-render-secrets.service")
    error_message = "terrateam.service [Unit] must declare Requires=terrateam-render-secrets.service so secrets are rendered before compose starts (G31: render-before-compose is a physical dependency, not implicit)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "After=docker.service network-online.target terrateam-render-secrets.service")
    error_message = "terrateam.service [Unit] must declare After=terrateam-render-secrets.service so render completes before compose starts"
  }
}

run "runcmd_no_longer_has_inline_ssm_fetch_heredoc" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "aws ssm get-parameter --with-decryption")
    error_message = "user-data must not perform inline runcmd SSM fetch — the render-secrets service is the single source of truth (G5: no duplicated fetch paths)"
  }
}

run "no_render_secrets_timer_unit_event_driven_only" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.this.user_data, "terrateam-render-secrets.timer")
    error_message = "rotation is event-driven via EventBridge → SSM RunCommand; no systemd timer should be installed (encodes the deliberate decision against polling)"
  }
}

run "cloudwatch_agent_installed_via_dnf" {
  command = plan

  assert {
    condition     = contains(yamldecode(aws_instance.this.user_data).packages, "amazon-cloudwatch-agent")
    error_message = "amazon-cloudwatch-agent must be in packages — ships render/compose journal to CloudWatch Logs for both boot and rotation paths"
  }
}

run "cw_agent_config_ships_render_secrets_log_to_cw_log_group" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json")
    error_message = "user-data must install a CW Agent config file"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/var/log/terrateam-render-secrets.log")
    error_message = "CW Agent must watch /var/log/terrateam-render-secrets.log (where the render unit's stdout/stderr is appended)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "/terrateam/render-secrets")
    error_message = "CW Agent config must ship to the /terrateam/render-secrets log group (matches the aws_cloudwatch_log_group resource)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "StandardOutput=append:/var/log/terrateam-render-secrets.log")
    error_message = "render-secrets unit must redirect stdout to the file the CW Agent watches (G22: physical wiring of script output → file → CW)"
  }

  assert {
    condition     = strcontains(aws_instance.this.user_data, "amazon-cloudwatch-agent-ctl -a fetch-config")
    error_message = "runcmd must load the CW Agent config via amazon-cloudwatch-agent-ctl so the agent starts collecting"
  }
}

run "cw_log_group_for_render_secrets_exists" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.render_secrets.name == "/terrateam/render-secrets"
    error_message = "module must create the /terrateam/render-secrets log group (matches CW Agent config and EventBridge RunCommand output config)"
  }

  assert {
    condition     = aws_cloudwatch_log_group.render_secrets.retention_in_days == 365
    error_message = "render-secrets log group must retain logs for 365 days (matches project convention from PR #118)"
  }
}

run "eventbridge_rule_matches_all_ssm_param_changes" {
  command = plan

  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.ssm_param_change.event_pattern).source == ["aws.ssm"]
    error_message = "EventBridge rule must match aws.ssm source events"
  }

  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.ssm_param_change.event_pattern)["detail-type"] ==
      ["Parameter Store Change"]
    )
    error_message = "EventBridge rule must match the SSM Parameter Store Change detail-type"
  }

  assert {
    condition = alltrue([
      for n in [
        "/terrateam/tunnel-token",
        "/terrateam/github-app-id",
        "/terrateam/github-app-pem",
        "/terrateam/github-app-client-id",
        "/terrateam/github-app-client-secret",
        "/terrateam/github-webhook-secret",
        "/terrateam/postgres-password",
      ] : contains(jsondecode(aws_cloudwatch_event_rule.ssm_param_change.event_pattern).detail.name, n)
    ])
    error_message = "EventBridge rule's detail.name list must include every /terrateam/* SSM parameter name — derived from var.user_data_inputs so the rule and the render script stay in sync (G22)"
  }
}

run "eventbridge_role_trusts_events_and_scopes_ssm_send_command" {
  command = plan

  assert {
    condition = strcontains(
      aws_iam_role.eventbridge_run_command.assume_role_policy,
      "events.amazonaws.com"
    )
    error_message = "EventBridge role's trust policy must allow events.amazonaws.com to assume it"
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.eventbridge_run_command.policy, "ssm:SendCommand")
    error_message = "EventBridge role must grant ssm:SendCommand — that's the only API the rule's target invokes"
  }

  assert {
    condition = strcontains(
      aws_iam_role_policy.eventbridge_run_command.policy,
      ":document/AWS-RunShellScript"
    )
    error_message = "EventBridge role must scope ssm:SendCommand to the AWS-RunShellScript document, not all documents"
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.eventbridge_run_command.policy, "\"Resource\":\"*\"")
    error_message = "EventBridge role must never use Resource:* — least-privilege scoping (G4 Overridden Safeties)"
  }
}

run "eventbridge_target_runs_render_secrets_via_ssm" {
  command = plan

  assert {
    condition     = strcontains(aws_cloudwatch_event_target.run_render_secrets.arn, ":document/AWS-RunShellScript")
    error_message = "EventBridge target must invoke the AWS-RunShellScript SSM document"
  }

  assert {
    condition = (
      length(aws_cloudwatch_event_target.run_render_secrets.run_command_targets) == 1 &&
      aws_cloudwatch_event_target.run_render_secrets.run_command_targets[0].key == "InstanceIds"
    )
    error_message = "EventBridge target must scope to a single InstanceIds targeting (least-privilege; one host fires for this host's params)"
  }

  assert {
    condition     = strcontains(aws_cloudwatch_event_target.run_render_secrets.input, "systemctl start terrateam-render-secrets.service")
    error_message = "EventBridge target's input must invoke the render-secrets unit (single renderer; G5 no duplicated trigger logic)"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_event_target.run_render_secrets.input, "CloudWatchOutputConfig")
    error_message = "Input passes through as AWS-RunShellScript document Parameters — SSM rejects unknown parameters, so SendCommand-level fields like CloudWatchOutputConfig must not appear here"
  }
}
