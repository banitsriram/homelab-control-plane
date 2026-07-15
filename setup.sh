#!/usr/bin/env bash
#
# setup.sh — turn a fresh Ubuntu Server box into the Homelab Control Plane node.
#
# Idempotent and modular: safe to re-run; every step checks before it changes
# anything. Run all steps, or name the ones you want:
#
#   sudo ./setup.sh                     # everything, interactive
#   sudo ./setup.sh --yes               # everything, no prompts
#   sudo ./setup.sh packages dashboard  # just those steps
#
# Steps:  packages  lid  ssh  firewall  dashboard  health  tailscale
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=0
STEPS=()

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    packages|lid|ssh|firewall|dashboard|health|tailscale) STEPS+=("$arg") ;;
    *) echo "unknown arg: $arg (steps: packages lid ssh firewall dashboard health tailscale)" >&2; exit 2 ;;
  esac
done
[ "${#STEPS[@]}" -eq 0 ] && STEPS=(packages lid ssh firewall dashboard health tailscale)

# The human who owns the physical dashboard — the real user, even under sudo.
DASHBOARD_USER="${SUDO_USER:-${DASHBOARD_USER:-$USER}}"
USER_HOME="$(getent passwd "$DASHBOARD_USER" | cut -d: -f6)"

c_cy=$'\033[36m'; c_gr=$'\033[32m'; c_yl=$'\033[33m'; c_rd=$'\033[31m'; c_0=$'\033[0m'
log()  { printf '%s▸ %s%s\n' "$c_cy" "$*" "$c_0"; }
ok()   { printf '%s✔ %s%s\n' "$c_gr" "$*" "$c_0"; }
warn() { printf '%s! %s%s\n' "$c_yl" "$*" "$c_0" >&2; }
die()  { printf '%s✗ %s%s\n' "$c_rd" "$*" "$c_0" >&2; exit 1; }
confirm() { [ "$ASSUME_YES" = 1 ] && return 0; read -rp "  $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo ./setup.sh"
[ -n "$USER_HOME" ] || die "can't resolve home directory for user '$DASHBOARD_USER'"

step_packages() {
  log "Installing packages"
  apt-get update -qq
  apt-get install -y -qq tmux btop tty-clock curl ufw ca-certificates >/dev/null
  if ! command -v gping >/dev/null; then
    snap install gping
    snap connect gping:network-observe   # raw ICMP socket, see ENGINEERING §4.1
  fi
  if ! command -v docker >/dev/null; then
    confirm "Docker not found — install it?" && curl -fsSL https://get.docker.com | sh
  fi
  ok "packages ready"
}

step_lid() {
  log "Ignoring lid-close so the box runs headless with the lid shut"
  install -d /etc/systemd/logind.conf.d
  install -m 644 "$REPO_DIR/configs/logind.conf.d/10-homelab-lid.conf" \
    /etc/systemd/logind.conf.d/10-homelab-lid.conf
  systemctl restart systemd-logind
  ok "lid switch ignored"
}

step_ssh() {
  log "Hardening SSH (key-only, no root, no passwords)"
  if [ ! -s "$USER_HOME/.ssh/authorized_keys" ] && ! command -v tailscale >/dev/null; then
    warn "no authorized_keys and no Tailscale detected — skipping to avoid a lockout."
    warn "set up key auth (or Tailscale SSH) first, then: sudo ./setup.sh ssh"
    return 0
  fi
  install -d /etc/ssh/sshd_config.d
  install -m 644 "$REPO_DIR/configs/sshd_config.d/10-homelab-hardening.conf" \
    /etc/ssh/sshd_config.d/10-homelab-hardening.conf
  if sshd -t; then systemctl reload ssh && ok "SSH hardened"
  else die "sshd config test failed — left unchanged"; fi
}

step_firewall() {
  log "Configuring firewall (ufw): deny-in, trust the tailnet"
  ufw --force default deny incoming  >/dev/null
  ufw --force default allow outgoing >/dev/null
  ufw allow in on tailscale0 >/dev/null 2>&1 || true  # tailnet is trusted
  ufw allow OpenSSH          >/dev/null               # LAN fallback so you can't lock yourself out
  ufw --force enable         >/dev/null
  ok "firewall active"
}

step_dashboard() {
  log "Wiring the physical-screen dashboard to boot for '$DASHBOARD_USER'"
  install -d /etc/systemd/system/getty@tty1.service.d
  sed "s/__USER__/$DASHBOARD_USER/g" \
    "$REPO_DIR/configs/getty@tty1.service.d/autologin.conf" \
    > /etc/systemd/system/getty@tty1.service.d/autologin.conf
  systemctl daemon-reload

  # Launch the dashboard when this user lands on the physical console (tty1).
  local hook="$USER_HOME/.bash_profile" marker="# >>> homelab-control-plane dashboard >>>"
  if ! grep -qF "$marker" "$hook" 2>/dev/null; then
    cat >> "$hook" <<EOF
$marker
if [[ "\$(tty)" == "/dev/tty1" && -z "\${TMUX:-}" ]]; then
  exec "$REPO_DIR/smart_display.sh"
fi
# <<< homelab-control-plane dashboard <<<
EOF
    chown "$DASHBOARD_USER": "$hook"
  fi
  ok "dashboard starts on boot (tty1) — set TARGET_IP in smart_display.sh"
}

step_health() {
  log "Installing the health-check timer (every 5 min)"
  sed "s#__REPO_DIR__#$REPO_DIR#g" "$REPO_DIR/configs/homelab-health.service" \
    > /etc/systemd/system/homelab-health.service
  install -m 644 "$REPO_DIR/configs/homelab-health.timer" \
    /etc/systemd/system/homelab-health.timer
  install -d /etc/homelab
  if [ ! -f /etc/homelab/health.env ]; then
    cat > /etc/homelab/health.env <<'EOF'
# Health-check config. NTFY_URL is where alerts are pushed (blank = syslog only).
# NTFY_URL=https://ntfy.sh/your-secret-topic
KAIROS_URL=http://localhost:8080/
DISK_THRESHOLD=90
EOF
  fi
  systemctl daemon-reload
  systemctl enable --now homelab-health.timer >/dev/null
  ok "health check enabled (edit /etc/homelab/health.env to turn on push alerts)"
}

step_tailscale() {
  log "Tailscale"
  if ! command -v tailscale >/dev/null; then
    confirm "Install Tailscale?" && curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    ok "tailscale up"
  else
    warn "run 'sudo tailscale up' to join your tailnet"
  fi
}

for s in "${STEPS[@]}"; do "step_$s"; done
echo
ok "Done. Steps run: ${STEPS[*]}"
