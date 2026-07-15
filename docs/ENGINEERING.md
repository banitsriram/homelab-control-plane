# Engineering Log

Full build notes for the Clutch Control Plane node — a Dell Latitude 3410 running headless Ubuntu Server, managed remotely from macOS.

The sections below cover what's actually built. Planned layers (Cloudflare Tunnel, Redis, cloud GPU burst) are listed in the [roadmap](#6-roadmap) and are not yet deployed.

---

## 1. Headless hardware configuration

The Latitude runs with its lid closed as an always-on server. By default Ubuntu suspends on lid close, so the `logind` behavior is overridden:

```bash
sudo nano /etc/systemd/logind.conf
# set:
#   HandleLidSwitch=ignore
#   HandleLidSwitchExternalPower=ignore

sudo systemctl restart systemd-logind
```

With that in place the machine keeps running — CPU, network, and SSH all live — with the lid shut.

## 2. Remote access (Tailscale)

The client (macOS) reaches the server over a private [Tailscale](https://tailscale.com) mesh VPN. This gives key-based SSH from any network — including restrictive campus/NAT environments — without opening any inbound ports or configuring port forwarding.

```bash
# On the server:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Each node gets a stable `100.x.x.x` address on the tailnet; the client SSHes to that address.

### Headless authentication — the tradeoff

Tailscale node keys expire periodically (default ~180 days) and normally need an interactive re-auth. On a headless box, an expired key silently locks the client out.

Two ways to handle it:

- **Disable key expiry** for this node in the Tailscale admin console. Simplest, but the node then holds a non-expiring key — weaker if the box is ever compromised.
- **Preferred:** provision the node with a [tagged auth key](https://tailscale.com/kb/1085/auth-keys) and manage access with ACLs. Keeps expiry semantics without manual re-auth.

This node currently uses disabled key expiry for simplicity; moving to a tagged auth key is a hardening step on the roadmap.

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

The node hosts **Kairos** (a personal life dashboard) via Docker Compose. Notes:

- Environment is injected at **container creation**, not runtime — after editing `.env`, recreate the service (`docker compose up -d <svc>`), don't just restart it.
- After a recreate the app needs a few seconds before it's listening; a connection refused right after boot means it's still starting.

## 6. Roadmap

The node is built to grow into a Brain/Brawn split. Not yet deployed:

- **Public ingress** — a Cloudflare Tunnel (`cloudflared`) to expose selected HTTP services through restrictive firewalls without inbound ports.
- **Async job queue** — Redis to distribute background jobs without blocking request I/O.
- **Cloud burst** — dispatch long-running ML workloads to on-demand GPU compute (GCP Compute Engine / RunPod) while the local node handles orchestration and state.
