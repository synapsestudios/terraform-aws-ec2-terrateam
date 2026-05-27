#!/usr/bin/env bash
# data.external program — runs on the machine running Terraform (the CI runner),
# OUTSIDE the instance. Curls the Elastic IP to prove the public ingress path that
# the in-instance SSM probe cannot reach: security group 80/443 open + EIP
# associated and routing + nginx reachable from the public internet.
#
# Protocol: reads a JSON query {"eip": "..."} on stdin, prints a JSON object of
# string->string on stdout, and ALWAYS exits 0 — the .tftest.hcl asserts on the
# returned codes so failures get a meaningful message instead of a generic error.
set -euo pipefail

eip="$(jq -r '.eip')"

http_redirect="000"
acme_code="000"
https_code="000"

# Retry: the SSM association already waited for nginx, but allow for EIP route
# propagation and TLS warm-up as seen from outside.
for _ in $(seq 1 24); do
  http_redirect="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$eip/" 2>/dev/null || echo 000)"
  acme_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$eip/.well-known/acme-challenge/probe" 2>/dev/null || echo 000)"
  https_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$eip/" 2>/dev/null || echo 000)"
  if [ "$http_redirect" = "301" ] && [ "$https_code" != "000" ]; then
    break
  fi
  sleep 5
done

jq -n \
  --arg http_redirect "$http_redirect" \
  --arg acme_code "$acme_code" \
  --arg https_code "$https_code" \
  '{http_redirect: $http_redirect, acme_code: $acme_code, https_code: $https_code}'
