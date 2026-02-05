#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Author: Marcos Azevedo (psylinux@gmail.com)
# Date: 2026-02-05
# Last Modified: 2026-02-05
# 
# Description: SOCKS5 over SSH tunnel with:
# - background mode
# - PID file
# - auto-restart on failure
#
# How to use:
#   ./socks-via-ssh start
#   ./socks-via-ssh stop
#   ./socks-via-ssh status
#   ./socks-via-ssh restart
#   ./socks-via-ssh logs
#
# ============================================================
# Notes:
# - SOCKS5 = proxy protocol
# - SSH    = Secure Shell (encrypted tunnel)
# - PID    = Process ID
# - TCP    = Transmission Control Protocol (reliable transport)
# ============================================================

# ----------------------------
# Config (edit as you like)
# ----------------------------
SSH_HOST="${SSH_HOST:-dark-horse}"
SSH_USER="${SSH_USER:-cowboy}"
SSH_PORT="${SSH_PORT:-2222}"

SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-1080}"

ALIVE_INTERVAL="${ALIVE_INTERVAL:-60}"
ALIVE_COUNTMAX="${ALIVE_COUNTMAX:-3}"

# Where to store PID/logs
STATE_DIR="${STATE_DIR:-$HOME/.socks-ssh-tunnel}"
PID_FILE="$STATE_DIR/tunnel.pid"
STOP_FLAG="$STATE_DIR/stop"
LOG_FILE="$STATE_DIR/tunnel.log"

# ----------------------------
# Helpers
# ----------------------------
ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE" >/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
}

is_running_pid() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

get_pid() {
  [[ -f "$PID_FILE" ]] && cat "$PID_FILE" || true
}

port_in_use() {
  # lsof exists by default on macOS
  lsof -nP -iTCP:"$SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

kill_pid_gracefully() {
  local pid="$1"
  if is_running_pid "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    # wait a bit
    for _ in {1..20}; do
      is_running_pid "$pid" || return 0
      sleep 0.1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

# ----------------------------
# Internal runner (auto-restart loop)
# ----------------------------
run_loop() {
  ensure_state_dir
  rm -f "$STOP_FLAG"
  echo "$$" > "$PID_FILE"
  log "tunnel supervisor started (PID=$$)"
  log "SOCKS5 listening on ${SOCKS_HOST}:${SOCKS_PORT} (local)"
  log "SSH target ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
  log "KeepAlive ServerAliveInterval=${ALIVE_INTERVAL}s ServerAliveCountMax=${ALIVE_COUNTMAX}"

  local backoff=1
  local max_backoff=30

  while true; do
    if [[ -f "$STOP_FLAG" ]]; then
      log "stop flag detected; exiting supervisor"
      break
    fi

    # If local port is already used, don't spin aggressively.
    if port_in_use; then
      log "port ${SOCKS_PORT}/TCP already in use; waiting..."
      sleep 2
      continue
    fi

    log "starting ssh dynamic forward (-D) ..."
    # Start SSH in foreground; if it dies, we restart.
    ssh -N -D "${SOCKS_HOST}:${SOCKS_PORT}" -p "${SSH_PORT}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval="${ALIVE_INTERVAL}" \
      -o ServerAliveCountMax="${ALIVE_COUNTMAX}" \
      "${SSH_USER}@${SSH_HOST}" >>"$LOG_FILE" 2>&1

    rc=$?
    log "ssh exited with code=$rc"

    if [[ -f "$STOP_FLAG" ]]; then
      log "stop flag set; not restarting"
      break
    fi

    log "restarting in ${backoff}s (auto-restart)"
    sleep "$backoff"
    if (( backoff < max_backoff )); then
      backoff=$(( backoff * 2 ))
      (( backoff > max_backoff )) && backoff=$max_backoff
    fi
  done

  rm -f "$PID_FILE" "$STOP_FLAG"
  log "tunnel supervisor stopped"
}

# ----------------------------
# Commands
# ----------------------------
cmd_start() {
  ensure_state_dir

  local pid
  pid="$(get_pid)"
  if [[ -n "$pid" ]] && is_running_pid "$pid"; then
    echo "Already running (PID=$pid). Use: $0 status | $0 stop | $0 logs"
    exit 0
  fi

  # Clean stale pidfile
  rm -f "$PID_FILE" "$STOP_FLAG"

  # Start supervisor in background (nohup keeps it alive if terminal closes)
  nohup "$0" _run_loop >/dev/null 2>&1 &
  disown || true

  # Wait briefly for pidfile
  for _ in {1..20}; do
    pid="$(get_pid)"
    if [[ -n "$pid" ]] && is_running_pid "$pid"; then
      echo "Started. Supervisor PID=$pid"
      echo "Logs: $LOG_FILE"
      exit 0
    fi
    sleep 0.1
  done

  die "Failed to start (no PID file). Check logs: $LOG_FILE"
}

cmd_stop() {
  ensure_state_dir

  local pid
  pid="$(get_pid)"
  if [[ -z "$pid" ]]; then
    echo "Not running (no PID file)."
    exit 0
  fi

  echo "Stopping (PID=$pid) ..."
  touch "$STOP_FLAG"
  kill_pid_gracefully "$pid"

  rm -f "$PID_FILE" "$STOP_FLAG"
  echo "Stopped."
}

cmd_status() {
  local pid
  pid="$(get_pid)"
  if [[ -n "$pid" ]] && is_running_pid "$pid"; then
    echo "RUNNING (PID=$pid) — SOCKS5 on ${SOCKS_HOST}:${SOCKS_PORT}"
    exit 0
  fi
  echo "STOPPED"
  exit 1
}

cmd_restart() {
  cmd_stop || true
  cmd_start
}

cmd_logs() {
  ensure_state_dir
  tail -n 200 -f "$LOG_FILE"
}

# ----------------------------
# Entry
# ----------------------------
case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  restart) cmd_restart ;;
  logs)    cmd_logs ;;
  _run_loop) run_loop ;;
  *)
    cat <<EOF
Usage: $0 [start|stop|status|restart|logs]

Environment overrides (optional):
  SSH_HOST, SSH_USER, SSH_PORT
  SOCKS_HOST, SOCKS_PORT
  ALIVE_INTERVAL, ALIVE_COUNTMAX
  STATE_DIR

Example:
  SSH_HOST=dark-horse SSH_USER=cowboy SSH_PORT=2222 \\
  SOCKS_PORT=1080 $0 start
EOF
    exit 2
    ;;
esac

