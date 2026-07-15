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
# The workload check reads Docker's own healthchecks (Kairos backend + caddy,
# redis, …), so it needs no per-app URLs or ports. Set KAIROS_URL for an extra
# explicit HTTP probe if you want one.
#
set -uo pipefail

NTFY_URL="${NTFY_URL:-}"                        # blank = syslog only
KAIROS_URL="${KAIROS_URL:-}"                    # optional extra HTTP probe
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"          # percent
HOST="$(hostname)"

problems=()

# Root disk usage.
disk="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
[ "${disk:-0}" -ge "$DISK_THRESHOLD" ] && problems+=("disk ${disk}% ≥ ${DISK_THRESHOLD}%")

# Docker daemon + any container reporting unhealthy.
if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}}' | paste -sd, -)"
    [ -n "$unhealthy" ] && problems+=("unhealthy containers: $unhealthy")
  else
    problems+=("docker daemon down")
  fi
fi

# Optional explicit HTTP probe (-k: Kairos uses Caddy's internal TLS).
if [ -n "$KAIROS_URL" ]; then
  curl -fksS --max-time 5 "$KAIROS_URL" >/dev/null 2>&1 \
    || problems+=("Kairos not responding at $KAIROS_URL")
fi

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
