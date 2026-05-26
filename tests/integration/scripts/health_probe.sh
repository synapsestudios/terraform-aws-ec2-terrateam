#!/bin/bash
# Run inside the test instance via SSM Run Command (AWS-RunShellScript).
# Three gates must pass before this script exits 0 — the SSM association
# then reaches Success and Terraform's apply unblocks:
#
#   0. cloud-init reached status=done (not error/degraded)
#   1. terrat-oss is bound to localhost:8080
#   2. postgres in the compose stack accepts connections (pg_isready)
#
# Gate 0 fails fast with the cloud-init diagnostic dump — that's the
# signal that user-data itself broke (e.g. a bad dnf package), distinct
# from the compose stack just being slow.

set -u

echo "Waiting for cloud-init to finish..."
if ! cloud-init status --wait; then
  echo "FAIL: cloud-init did not reach status=done"
  cloud-init status --long
  exit 1
fi
echo "OK: cloud-init done"

PORT_OPEN=0
PG_READY=0

for i in $(seq 1 120); do
  if [ "$PORT_OPEN" -eq 0 ] && (echo > /dev/tcp/localhost/8080) 2>/dev/null; then
    echo "OK: port 8080 accepting connections (attempt $i)"
    PORT_OPEN=1
  fi

  if [ "$PG_READY" -eq 0 ] && docker compose -f /opt/terrateam/docker-compose.yml exec -T postgres \
       pg_isready -U terrateam -d terrateam >/dev/null 2>&1; then
    echo "OK: postgres ready (attempt $i)"
    PG_READY=1
  fi

  if [ "$PORT_OPEN" -eq 1 ] && [ "$PG_READY" -eq 1 ]; then
    echo "All checks passed"
    exit 0
  fi

  echo "attempt $i: port_8080=$PORT_OPEN postgres=$PG_READY"
  sleep 5
done

echo "FAIL: probe timed out (port_8080=$PORT_OPEN postgres=$PG_READY)"
exit 1
