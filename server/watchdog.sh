#!/usr/bin/env bash
# Держит живыми голосовой сервер (127.0.0.1:8787) и tailscaled (Funnel -> https://voice-gw.tail22b878.ts.net).
# Cron: @reboot и */5.  ./watchdog.sh restart — перезапустить сервер после правок. Ничего не делает, если всё уже работает.  Остановить:  touch ~/ws/garmin/.paused
set -uo pipefail
export HOME=/home/claude PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
G="$HOME/ws/garmin"; S="$G/server"; T="$G/tools/tailscale"; D="$HOME/.local/share/tailscale-voice"
LOG="$HOME/ws/logs/garmin-voice.log"
[ -e "$G/.paused" ] && exit 0

if ! pgrep -u "$USER" -f "tailscaled .*--statedir=$D" >/dev/null; then
  echo "$(date -Is) start tailscaled" >>"$LOG"
  nohup "$T/tailscaled" --tun=userspace-networking --statedir="$D" --socket="$D/tailscaled.sock" --port=0 --verbose="${TS_VERBOSE:-0}" \
    >>"$HOME/ws/logs/tailscaled.log" 2>&1 &
  # конфиг Funnel хранится в state и поднимается сам
fi

if [ "${1:-}" = restart ] || ! curl -s -m 5 http://127.0.0.1:8787/v1/health >/dev/null; then
  pkill -u "$USER" -f "$S/app.py" 2>/dev/null; sleep 1
  echo "$(date -Is) start voice server" >>"$LOG"
  cd "$S" && nohup "$S/.venv/bin/python" "$S/app.py" >>"$LOG" 2>&1 &
fi
