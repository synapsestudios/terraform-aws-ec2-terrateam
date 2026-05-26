run "deploy_and_probe_terrateam_port" {
  command = apply

  # Explicit (matches the harness default) so this lane's mode is self-documenting
  # and stays cloudflare_tunnel even if the default ever changes.
  variables {
    ingress_mode = "cloudflare_tunnel"
  }

  assert {
    condition     = aws_ssm_association.wait_for_terrateam.id != ""
    error_message = "SSM health-probe association should reach Success. If apply failed, see SSM command history."
  }
}
