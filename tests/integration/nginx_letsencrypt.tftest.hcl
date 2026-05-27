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

  # In-instance wiring: the SSM association blocks apply until the in-box probe
  # exits 0 (cloud-init done, cert-renew timer enabled, :80 redirect/ACME, :443 ->
  # terrat-oss proxy, postgres). Reaching this assert means that probe passed.
  assert {
    condition     = aws_ssm_association.wait_for_terrateam.id != ""
    error_message = "in-instance probe must reach Success (proxy chain + timer + postgres). If apply failed, see SSM command history."
  }

  # Public ingress path (the part the in-box probe can't reach): these come from a
  # runner-side curl of the EIP, so they exercise the security group AND the EIP
  # association AND external nginx reachability end to end.
  assert {
    condition     = data.external.ingress_probe[0].result.http_redirect == "301"
    error_message = "External HTTP on the EIP must 301-redirect to HTTPS — proves SG :80 open + EIP associated/routing + nginx reachable from the public internet (not just localhost)."
  }

  assert {
    condition     = data.external.ingress_probe[0].result.acme_code == "404"
    error_message = "External ACME challenge path on the EIP must be served by nginx (404 for a missing file, not 301) — proves the HTTP-01 path is publicly reachable, which real Let's Encrypt issuance depends on."
  }

  assert {
    condition     = !contains(["000", "502", "504"], data.external.ingress_probe[0].result.https_code)
    error_message = "External HTTPS on the EIP must reach terrat-oss through nginx — proves SG :443 + EIP + TLS termination + reverse proxy all work from the public internet (got ${data.external.ingress_probe[0].result.https_code})."
  }
}
