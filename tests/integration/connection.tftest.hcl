run "deploy_and_probe_terrateam_port" {
  command = apply

  assert {
    condition     = aws_ssm_association.wait_for_terrateam.id != ""
    error_message = "SSM health-probe association should reach Success. If apply failed, see SSM command history."
  }
}
