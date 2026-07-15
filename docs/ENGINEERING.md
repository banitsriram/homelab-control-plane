# Engineering Log

Full build notes for the Homelab Control Plane node — a Dell Latitude 3410 running headless Ubuntu Server, managed remotely from macOS.

Everything below is applied by [`setup.sh`](../setup.sh) (idempotent, one step per section) — the manual commands are here so you understand *what* it does, not because you have to run them by hand. Planned layers (Cloudflare Tunnel, Redis, cloud GPU burst) are in the [roadmap](#9-roadmap) and not yet deployed.

## Contents

1. [Headless hardware configuration](#1-headless-hardware-configuration)
2. [Remote access (Tailscale)](#2-remote-access-tailscale)
3. [The telemetry dashboard](#3-the-telemetry-dashboard)
4. [Debugging log — five real bugs](#4-debugging-log)
5. [Application host — Kairos](#5-application-host--kairos)
6. [Security perimeter](#6-security-perimeter)
7. [Health & alerting](#7-health--alerting)
8. [One-command bootstrap](#8-one-command-bootstrap)
9. [Roadmap](#9-roadmap)

---

## 1. Headless hardware configuration

The Latitude runs with its lid closed as an always-on server. By default Ubuntu suspends on lid close, so the `logind` behavior is overridden with a drop-in — [`configs/logind.conf.d/10-homelab-lid.conf`](../configs/logind.conf.d/10-homelab-lid.conf):

```ini
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

```bash
sudo systemctl restart systemd-logind
```

With that in place the machine keeps running — CPU, network, and SSH all live — with the lid shut.

## 2. Remote access (Tailscale)

The client (macOS) reaches the server over a private [Tailscale](https://tailscale.com) mesh VPN. This gives key-based SSH from any network — including restrictive campus/NAT environments — without opening any inbound ports or configuring port forwarding.

```bash
# On the server:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Each node gets a stable `100.x.x.x` address on the tailnet; the client SSHes to that address.

### Headless authentication — the tradeoff

Tailscale node keys expire periodically (default ~180 days) and normally need an interactive re-auth. On a headless box, an expired key silently locks the client out.

Two ways to handle it:

- **Disable key expiry** for this node in the admin console. Simplest, but the node then holds a non-expiring key — weaker if the box is ever compromised.
- **Preferred:** provision the node with a [tagged auth key](https://tailscale.com/kb/1085/auth-keys) and manage access with ACLs. Keeps expiry semantics without manual re-auth. A ready-to-paste policy is in [`configs/tailscale-acl.hujson`](../configs/tailscale-acl.hujson):

  ```bash
  sudo tailscale up --ssh --advertise-tags=tag:homelab --authkey <key>
  ```

This node started on disabled key expiry for simplicity; the tagged-key + ACL move is the documented hardening path.

## 3. The telemetry dashboard

`smart_display.sh` (repo root) renders a live, always-on dashboard on the laptop's physical screen using `tmux`:

- **Pane 0 (left):** `btop` — system vitals
- **Pane 1 (top-right):** `gping` — link pulse to a target host
- **Pane 2 (bottom-right):** `tty-clock`

### Dependencies

```bash
sudo apt update
sudo apt install -y tmux btop tty-clock
sudo snap install gping
sudo snap connect gping:network-observe
```

### 3.1 Surviving a reboot

A dashboard you have to relaunch by hand after every power blip isn't "always-on." The fix is autologin on the physical console plus a shell hook that exec's the script:

- **tty1 autologin** — [`configs/getty@tty1.service.d/autologin.conf`](../configs/getty@tty1.service.d/autologin.conf) overrides `getty@tty1` to log the dashboard user in automatically:

  ```ini
  [Service]
  ExecStart=
  ExecStart=-/sbin/agetty --autologin <user> --noclear %I $TERM
  ```

- **launch hook** — `setup.sh` appends a guarded block to the user's `~/.bash_profile` so the dashboard starts *only* on the physical console, and never nests inside an existing tmux:

  ```bash
  if [[ "$(tty)" == "/dev/tty1" && -z "${TMUX:-}" ]]; then
    exec "$REPO_DIR/smart_display.sh"
  fi
  ```

The trade-off is explicit: anyone at the physical keyboard lands in a logged-in shell. Acceptable for a lid-closed box in your own space; don't do it on hardware other people can reach.

## 4. Debugging log

Five real problems hit while building the dashboard, and how each was fixed.

### 4.1 — `gping`: Permission denied inside Snap confinement

**Symptom:** `gping` threw `Permission denied` in its pane.
**Cause:** installed via Snap, which runs under AppArmor confinement. Raw ICMP sockets (`CAP_NET_RAW`) are blocked by default.
**Fix:** connect the network-observe interface to grant socket access:

```bash
sudo snap connect gping:network-observe
```

### 4.2 — Ping pane dies on an unreachable host

**Symptom:** if the target IP was down or invalid, `gping` exited and left the pane at a frozen error / dead shell.
**Cause:** the pane ran a single instance; once it exited, nothing restarted it.
**Fix:** wrap it in a `while true` loop with a short sleep so the pane self-heals:

```bash
while true; do gping "$TARGET_IP"; sleep 1; done
```

### 4.3 — `btop` drops modules on the 14" screen

**Symptom:** on the internal 14" display (vs. an external monitor), `btop`'s lower graphs disappeared.
**Cause:** `btop` scales to terminal rows/columns and drops modules below a minimum size to protect the core CPU/RAM view.
**Fix:** lock the left pane width in the launch script so the layout stays above the threshold:

```bash
tmux resize-pane -t Dashboard:0.0 -x 90
```

(Interactive fallback: focus the pane and press `3` to toggle the network module back on.)

### 4.4 — `Ctrl-C` killing the clock pane

**Symptom:** switching focus sometimes sent `Ctrl-C` into the clock pane, killing `tty-clock` and blanking it.
**Cause:** `SIGINT` reached the foreground process instead of being caught by the tmux prefix.
**Fix:** ignore `SIGINT` in the pane before launching the binary:

```bash
trap "" SIGINT
```

### 4.5 — The stray green status bar

**Symptom:** an unwanted green line along the bottom of the screen.
**Cause:** the default tmux status bar — wasted a row and clashed with the clock pane.
**Fix:** turn it off globally:

```bash
tmux set-option -g status off
```

## 5. Application host — Kairos

The node hosts **Kairos** (a personal life dashboard) via Docker Compose. The compose file ([`docker-compose.yml`](../docker-compose.yml)) encodes what was learned running it:

- Environment is injected at **container creation**, not runtime — after editing `.env`, recreate the service (`docker compose up -d kairos`), don't just restart it.
- After a recreate the app needs a few seconds before it's listening; a connection refused right after boot means it's still starting — the compose `healthcheck` (with a `start_period`) models exactly this.
- `restart: unless-stopped` brings it back after a host reboot; `json-file` log rotation keeps a chatty app from filling the disk.

## 6. Security perimeter

A node reachable from anywhere needs a real perimeter. `setup.sh` applies three layers:

- **SSH** — [`configs/sshd_config.d/10-homelab-hardening.conf`](../configs/sshd_config.d/10-homelab-hardening.conf): key-only, no root, no passwords, `MaxAuthTries 3`. The bootstrap refuses to apply it unless it first finds `authorized_keys` **or** Tailscale SSH — so it can't strand you. (Tailscale SSH doesn't go through `sshd`, so it keeps working even if the config is wrong; a useful backstop.)
- **Firewall** — `ufw` set to deny-inbound by default, allow-all outbound, trust the `tailscale0` interface, and keep a LAN `OpenSSH` fallback so a tailnet hiccup can't lock you out:

  ```bash
  ufw default deny incoming
  ufw allow in on tailscale0
  ufw allow OpenSSH
  ufw enable
  ```

- **Tailnet** — the [ACL example](../configs/tailscale-acl.hujson) scopes who can reach the tagged node and who can SSH to it as a non-root user.

## 7. Health & alerting

The dashboard is for when you're *looking*; the health timer is for when you're not. [`healthcheck.sh`](../healthcheck.sh) runs from a systemd timer ([`configs/homelab-health.timer`](../configs/homelab-health.timer)) every 5 minutes and checks:

- root disk usage against a threshold,
- the Docker daemon,
- the Kairos HTTP endpoint,
- the Tailscale link.

On failure it pushes to [ntfy](https://ntfy.sh) and writes to syslog; it always exits `0` so a transient blip doesn't mark the unit failed. Config lives in `/etc/homelab/health.env`:

```bash
NTFY_URL=https://ntfy.sh/your-secret-topic
KAIROS_URL=http://localhost:8080/
DISK_THRESHOLD=90
```

Inspect it like any timer:

```bash
systemctl list-timers homelab-health.timer
journalctl -t homelab-health --since -1h
```

## 8. One-command bootstrap

[`setup.sh`](../setup.sh) turns a fresh Ubuntu box into everything above. It's **idempotent** (safe to re-run) and **modular** (run a subset by naming steps):

```bash
sudo ./setup.sh                     # everything, interactive
sudo ./setup.sh --yes               # everything, no prompts
sudo ./setup.sh ssh firewall        # just the perimeter
```

Steps: `packages · lid · ssh · firewall · dashboard · health · tailscale`. Each checks the current state before changing anything and prints what it did. `shellcheck` runs on every script in CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)), which also validates the compose file.

## 9. Roadmap

The node is built to grow into a Brain/Brawn split. Not yet deployed:

- **Public ingress** — a Cloudflare Tunnel (`cloudflared`) to expose selected HTTP services through restrictive firewalls without inbound ports.
- **Async job queue** — Redis to distribute background jobs without blocking request I/O.
- **Cloud burst** — dispatch long-running ML workloads to on-demand GPU compute (GCP Compute Engine / RunPod) while the local node handles orchestration and state.
