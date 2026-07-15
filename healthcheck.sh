#!/usr/bin/env bash
#
# healthcheck.sh — probe the node and its workloads, push an alert if something
# is wrong. Driven by a systemd timer (see configs/homelab-health.timer), but
# runnable by hand too. Always exits 0 so a transient blip doesn't mark the
# unit failed — real problems go out as an ntfy push and to syslog.
#
#   ./healthcheck.sh                       # log-only
#   NTFY_URL=https://ntfy.sh/topic ./healthcheck.sh
#
set -uo pipefail

NTFY_URL="${NTFY_URL:-}"                                # blank = syslog only
KAIROS_URL="${KAIROS_URL:-http://localhost:8080/}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"                  # percent
HOST="$(hostname)"

problems=()

# Root disk usage.
disk="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
[ "${disk:-0}" -ge "$DISK_THRESHOLD" ] && problems+=("disk ${disk}% ≥ ${DISK_THRESHOLD}%")

# Docker daemon.
if command -v docker >/dev/null; then
  docker info >/dev/null 2>&1 || problems+=("docker daemon down")
fi

# Kairos HTTP endpoint.
curl -fsS --max-time 5 "$KAIROS_URL" >/dev/null 2>&1 \
  || problems+=("Kairos not responding at $KAIROS_URL")

# Tailscale link.
if command -v tailscale >/dev/null; then
  tailscale status >/dev/null 2>&1 || problems+=("tailscale down")
fi

if [ "${#problems[@]}" -eq 0 ]; then
  logger -t homelab-health "ok"
  exit 0
fi

msg="⚠️ ${HOST}: $(IFS='; '; echo "${problems[*]}")"
logger -t homelab-health "$msg"
[ -n "$NTFY_URL" ] && curl -fsS -H "Title: Homelab alert" -d "$msg" "$NTFY_URL" >/dev/null 2>&1 || true
exit 0
