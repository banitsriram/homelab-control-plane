# ⚡ Clutch Control Plane

A recycled **Dell Latitude 3410** turned into a 24/7 headless Ubuntu server — the always-on **"Brain"** of a home lab: reachable from anywhere over Tailscale SSH, running with the lid closed, with a physical-screen ops dashboard and application workloads in Docker.

The design goal is a **Brain / Brawn split**: cheap local hardware stays on 24/7 to handle orchestration, state, and long-running processes, while heavy ML compute bursts out to on-demand cloud GPUs. This repo is the *control plane* — the always-on node that makes that possible — plus the tooling that runs on it.

## Status — built vs. planned

Honest scope. Everything marked ✅ is running today; 🧭 is the roadmap the node is built to grow into.

| Layer | What | State |
|---|---|---|
| Compute node | Headless Ubuntu on a Dell Latitude 3410, lid-closed, 24/7 | ✅ Running |
| Remote access | Tailscale SSH from a macOS client — no port forwarding | ✅ Running |
| Ops dashboard | `tmux` triple-pane physical-screen telemetry (`btop` / `gping` / `tty-clock`) | ✅ Running |
| Application host | **Kairos** (personal life dashboard) via Docker Compose | ✅ Running |
| Public ingress | Cloudflare Tunnel (`cloudflared`) for firewall-friendly HTTP | 🧭 Planned |
| Job queue | Redis-backed async worker model | 🧭 Planned |
| Cloud burst | Dispatch ML jobs to GCP Compute / RunPod GPUs | 🧭 Planned |

## Architecture

```
        macOS client                     ┌─────────────── The Brain ───────────────┐
        (remote terminal)                │  Dell Latitude 3410 · Ubuntu · headless  │
             │                           │                                          │
             │   Tailscale SSH           │   ┌────────────┐   ┌──────────────────┐  │
             └──────────(mesh VPN)───────┼──▶│ smart_     │   │ Docker Compose   │  │
                                         │   │ display.sh │   │  └─ Kairos (app)  │  │
                                         │   │ (tmux ops) │   └──────────────────┘  │
                                         │   └────────────┘                         │
                                         └──────────────────────────────────────────┘
                                                          │
                                         🧭 planned:  Redis queue → cloud GPU burst
                                                      (GCP / RunPod)  ── The Brawn
```

## The hardware

An old **Dell Latitude 3410** running a minimal Ubuntu Server install, mounted lid-closed as an always-on node. Repurposing e-waste into a real 24/7 server — no cloud bill, full control of the box.

Running headless with the lid shut means overriding the default suspend-on-lid behavior; see [`docs/ENGINEERING.md`](docs/ENGINEERING.md#1-headless-hardware-configuration).

## The ops dashboard

`smart_display.sh` turns the laptop's own screen into a live telemetry board using `tmux`:

- **Left** — `btop`: CPU / RAM / disk / network vitals
- **Top-right** — `gping`: link pulse to a target host
- **Bottom-right** — `tty-clock`

```bash
chmod +x smart_display.sh
TARGET_IP=<your-host> ./smart_display.sh
```

The panes run inside self-healing loops with `SIGINT` traps, so a dropped host or a stray `Ctrl-C` can't leave a dead shell on the screen. The full build story — including five real bugs and their fixes — is in [`docs/ENGINEERING.md`](docs/ENGINEERING.md).

### Dependencies

```bash
sudo apt update
sudo apt install -y tmux btop tty-clock
sudo snap install gping
sudo snap connect gping:network-observe   # grant raw-socket access for ICMP
```

## Remote access (Tailscale)

The node joins a private Tailscale mesh, so the macOS client can SSH in over any network — including restrictive campus/NAT setups — with no inbound ports opened. Setup and the headless-authentication tradeoff are documented in [`docs/ENGINEERING.md`](docs/ENGINEERING.md#2-remote-access-tailscale).

## Deep dive

[`docs/ENGINEERING.md`](docs/ENGINEERING.md) — full build log: headless configuration, the Tailscale ingress layer, the dashboard, and the debugging log behind it.

## License

[MIT](LICENSE)
