#!/bin/bash
# Run inside the test instance via SSM Run Command for ingress_mode=nginx_letsencrypt.
# Verifies the nginx reverse-proxy chain end to end (no real DNS, so nginx serves
# its self-signed bootstrap cert and we curl with -k):
#
#   0. cloud-init reached status=done
#   1. :80 serves the ACME HTTP-01 location from the webroot (404, NOT a 301) and
#      301-redirects everything else to HTTPS
#   2. :443 terminates TLS and reverse-proxies to terrat-oss (any terrat-oss status,
#      i.e. not 000/502/504 — those mean nginx couldn't reach the upstream)
#   3. postgres in the compose stack accepts connections
#
# This proves the SG/compose/nginx.conf/proxy wiring the module owns. Real
# Let's Encrypt issuance is not exercised here (it needs a public DNS name
# resolving to the EIP — gated to a real test domain on LE staging).

set -u

COMPOSE="docker compose -f /opt/terrateam/docker-compose.yml"
HOSTHDR="terrateam.test.invalid"

echo "Waiting for cloud-init to finish..."
if ! cloud-init status --wait; then
  echo "FAIL: cloud-init did not reach status=done"
  cloud-init status --long
  exit 1
fi
echo "OK: cloud-init done"

# The renewal mechanism must actually be wired up, not just present as a file.
if ! systemctl is-enabled --quiet terrateam-cert-renew.timer; then
  echo "FAIL: terrateam-cert-renew.timer is not enabled"
  systemctl status terrateam-cert-renew.timer --no-pager || true
  exit 1
fi
echo "OK: cert-renew timer enabled"

PROXY_OK=0
for i in $(seq 1 120); do
  # :80 — everything except the ACME path 301-redirects to HTTPS.
  redirect=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null || true)
  # :80 — the ACME challenge location is served from the webroot (missing file => 404, not 301).
  acme=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/.well-known/acme-challenge/probe 2>/dev/null || true)
  # :443 — TLS terminates (self-signed => -k) and nginx proxies to terrat-oss.
  https=$(curl -sk -o /dev/null -w '%{http_code}' -H "Host: $HOSTHDR" https://localhost/ 2>/dev/null || true)

  if [ "$redirect" = "301" ] && [ "$acme" = "404" ] && \
     [ -n "$https" ] && [ "$https" != "000" ] && [ "$https" != "502" ] && [ "$https" != "504" ]; then
    echo "OK: :80 redirect=$redirect acme=$acme ; :443 proxied to terrat-oss https=$https (attempt $i)"
    PROXY_OK=1
    break
  fi

  echo "attempt $i: http_redirect=$redirect acme=$acme https_proxy=$https"
  sleep 5
done

if [ "$PROXY_OK" -ne 1 ]; then
  echo "FAIL: nginx reverse-proxy chain not healthy"
  $COMPOSE ps || true
  echo "--- nginx logs ---"; $COMPOSE logs --tail=50 nginx || true
  echo "--- certbot logs ---"; $COMPOSE logs --tail=30 certbot || true
  exit 1
fi

for i in $(seq 1 60); do
  if $COMPOSE exec -T postgres pg_isready -U terrateam -d terrateam >/dev/null 2>&1; then
    echo "OK: postgres ready (attempt $i)"
    echo "All checks passed"
    exit 0
  fi
  echo "attempt $i: postgres not ready yet"
  sleep 5
done

echo "FAIL: postgres did not become ready"
exit 1
