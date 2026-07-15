#!/bin/bash
#
# smart_display.sh — physical-screen ops dashboard for the headless server.
# Splits the laptop's own terminal into a 24/7 telemetry view with tmux:
#   left  : btop       (CPU / RAM / disk / net)
#   top-R : gping      (link pulse to a target host)
#   bot-R : tty-clock
#
# Target host for the ping pane. Override without editing this file:
#   TARGET_IP=100.100.1.2 ./smart_display.sh
TARGET_IP="${TARGET_IP:-100.x.x.x}"

# Bail early with a clear message if a required tool is missing.
for cmd in tmux btop gping tty-clock; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing dependency: $cmd — see README (Dependencies)" >&2
    exit 1
  fi
done

if [ "$TARGET_IP" = "100.x.x.x" ]; then
  echo "warning: TARGET_IP is still the placeholder; the ping pane won't resolve." >&2
  echo "         run as: TARGET_IP=<your-host> ./smart_display.sh" >&2
fi

# Clean slate — kill any old session so panes don't stack up.
tmux kill-session -t Dashboard 2>/dev/null
tmux new-session -d -s Dashboard

# Hide the status bar to reclaim a row on the small physical screen.
tmux set-option -g status off

# Left pane: hardware vitals.
tmux send-keys -t Dashboard "btop" C-m

# Top-right pane: link pulse. Wrapped in a loop + SIGINT trap so a dropped
# host or a stray Ctrl-C can't leave the pane at a dead shell.
tmux split-window -h -t Dashboard
tmux send-keys -t Dashboard "trap '' SIGINT; while true; do gping ${TARGET_IP}; sleep 1; done" C-m

# Bottom-right pane: clock, same self-healing loop.
tmux split-window -v -t Dashboard:0.1
tmux send-keys -t Dashboard "trap '' SIGINT; while true; do tty-clock -s -C 6; sleep 1; done" C-m

# Lock the left pane width so btop's graphs render on a 14" screen.
tmux resize-pane -t Dashboard:0.0 -x 90

# Touchpad/mouse focus + a visible active-pane border.
tmux set-option -g mouse on
tmux set-option -g pane-active-border-style fg=cyan

tmux attach-session -t Dashboard
