#!/usr/bin/env bash
# data.external program — runs on the machine running Terraform (the CI runner),
# OUTSIDE the instance. Curls the Elastic IP to prove the public ingress path that
# the in-instance SSM probe cannot reach: security group 80/443 open + EIP
# associated and routing + nginx reachable from the public internet.
#
# It uses --resolve to behave like a real client: DNS name -> EIP, so the request
# carries the correct Host header and TLS SNI (terrat-oss returns 502 via nginx if
# the Host is the bare IP, which a real DNS client never sends).
#
# Protocol: reads a JSON query {"eip":"...","host":"..."} on stdin, prints a JSON
# object of string->string on stdout, and ALWAYS exits 0 — the .tftest.hcl asserts
# on the returned codes so failures get a meaningful message.
set -euo pipefail

query="$(cat)"
eip="$(jq -r '.eip' <<<"$query")"
host="$(jq -r '.host' <<<"$query")"

http_redirect="000"
acme_code="000"
https_code="000"

probe_http() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:80:$eip" "http://$host$1" 2>/dev/null || echo 000; }
probe_https() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:443:$eip" "https://$host/" 2>/dev/null || echo 000; }

# Retry until a genuine proxied response (not 000/502/504) — terrat-oss may still
# be warming up just after the in-box probe released the apply.
for _ in $(seq 1 36); do
  http_redirect="$(probe_http /)"
  acme_code="$(probe_http /.well-known/acme-challenge/probe)"
  https_code="$(probe_https)"
  if [ "$http_redirect" = "301" ] && [ "$https_code" != "000" ] && [ "$https_code" != "502" ] && [ "$https_code" != "504" ]; then
    break
  fi
  sleep 5
done

jq -n \
  --arg http_redirect "$http_redirect" \
  --arg acme_code "$acme_code" \
  --arg https_code "$https_code" \
  '{http_redirect: $http_redirect, acme_code: $acme_code, https_code: $https_code}'
