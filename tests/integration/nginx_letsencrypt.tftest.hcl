# Integration test for ingress_mode = "nginx_letsencrypt". Deploys the full stack
# with a real Elastic IP and runs the nginx proxy-chain probe inside the instance
# (see scripts/health_probe_nginx.sh). The apply blocks on the SSM association
# reaching Success, so reaching apply == the proxy chain is healthy.
#
# Real Let's Encrypt issuance is NOT exercised here — it needs a public DNS name
# resolving to the EIP. nginx serves its self-signed bootstrap cert and the probe
# curls with -k; the issuance path is validated separately against a real test
# domain on the LE staging endpoint.

run "deploy_nginx_letsencrypt_and_probe_proxy" {
  command = apply

  variables {
    ingress_mode = "nginx_letsencrypt"
  }

  assert {
    condition     = length(aws_eip.this) == 1
    error_message = "nginx_letsencrypt integration must allocate a caller-owned EIP"
  }

  assert {
    condition     = aws_ssm_association.wait_for_terrateam.id != ""
    error_message = "nginx_letsencrypt probe must reach Success: :80 ACME location + 301 redirect and :443 -> terrat-oss proxy chain healthy. If apply failed, see SSM command history."
  }
}
