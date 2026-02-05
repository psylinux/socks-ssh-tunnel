#!/usr/bin/env bash
# MIT License
#
# Copyright (c) 2026 Marcos Azevedo
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

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
# Notes:
# - SOCKS5 = proxy protocol (Socket Secure v5: proxy TCP/UDP via um endpoint)
# - SSH    = Secure Shell (túnel criptografado)
# - PID    = Process ID (identificador do processo)
# - TCP    = Transmission Control Protocol (transporte confiável)
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

# If 1, stop/start will also kill *orphan ssh listeners* on SOCKS_PORT.
# (Conservador: só mata processo "ssh" que está LISTEN na porta)
KILL_SSH_LISTENERS_ON_PORT="${KILL_SSH_LISTENERS_ON_PORT:-1}"

# Where to store PID/logs
STATE_DIR="${STATE_DIR:-$HOME/.socks-ssh-tunnel}"
PID_FILE="$STATE_DIR/tunnel.pid"
STOP_FLAG="$STATE_DIR/stop"
LOG_FILE="$STATE_DIR/tunnel.log"
SSH_PID_FILE="$STATE_DIR/ssh.pid"

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

get_ssh_pid() {
  [[ -f "$SSH_PID_FILE" ]] && cat "$SSH_PID_FILE" || true
}

# True if ANY process is listening on SOCKS_PORT/TCP
port_in_use() {
  lsof -nP -iTCP:"$SOCKS_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

# Return PIDs listening on SOCKS_PORT/TCP
listener_pids() {
  lsof -nP -iTCP:"$SOCKS_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true
}

pid_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

kill_pid_gracefully() {
  local pid="$1"
  if is_running_pid "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      is_running_pid "$pid" || return 0
      sleep 0.1
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

# Kill ssh processes that are LISTENing on SOCKS_PORT/TCP.
# This handles orphaned tunnels like the one you had (PPID=1).
kill_ssh_listeners_on_port() {
  [[ "$KILL_SSH_LISTENERS_ON_PORT" == "1" ]] || return 0

  local pids
  pids="$(listener_pids)"
  [[ -z "$pids" ]] && return 0

  for pid in $pids; do
    local cmd
    cmd="$(pid_command "$pid")"
    [[ -z "$cmd" ]] && continue

    # Only kill if it's ssh (conservador)
    if [[ "$cmd" == ssh\ * || "$cmd" == */ssh\ * ]]; then
      log "killing ssh listener on ${SOCKS_HOST}:${SOCKS_PORT} (PID=$pid) cmd='$cmd'"
      kill_pid_gracefully "$pid"
    fi
  done
}

show_port_listeners() {
  echo "Listeners on TCP/${SOCKS_PORT}:"
  lsof -nP -iTCP:"$SOCKS_PORT" -sTCP:LISTEN || true
}

# ----------------------------
# Internal runner (auto-restart loop)
# ----------------------------
run_loop() {
  ensure_state_dir
  rm -f "$STOP_FLAG"
  echo "$$" > "$PID_FILE"

  cleanup() {
    local ssh_pid
    ssh_pid="$(get_ssh_pid)"
    if [[ -n "$ssh_pid" ]]; then
      kill_pid_gracefully "$ssh_pid"
      rm -f "$SSH_PID_FILE"
    fi
    rm -f "$PID_FILE" "$STOP_FLAG"
    log "tunnel supervisor stopped"
  }
  trap cleanup EXIT INT TERM

  log "tunnel supervisor started (PID=$$)"
  log "SOCKS5 listening on ${SOCKS_HOST}:${SOCKS_PORT} (local)"
  log "SSH target ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
  log "KeepAlive ServerAliveInterval=${ALIVE_INTERVAL}s ServerAliveCountMax=${ALIVE_COUNTMAX}"

  local backoff=1
  local max_backoff=30

  while true; do
    [[ -f "$STOP_FLAG" ]] && { log "stop flag detected; exiting supervisor"; break; }

    # If local port is used, wait. (start should avoid this; still, be safe.)
    if port_in_use; then
      log "port ${SOCKS_PORT}/TCP already in use; waiting..."
      sleep 2
      continue
    fi

    log "starting ssh dynamic forward (-D) ..."
    ssh -N -D "${SOCKS_HOST}:${SOCKS_PORT}" -p "${SSH_PORT}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval="${ALIVE_INTERVAL}" \
      -o ServerAliveCountMax="${ALIVE_COUNTMAX}" \
      "${SSH_USER}@${SSH_HOST}" >>"$LOG_FILE" 2>&1 &
    ssh_pid="$!"
    echo "$ssh_pid" > "$SSH_PID_FILE"

    rc=0
    if wait "$ssh_pid"; then
      rc=0
    else
      rc=$?
    fi
    rm -f "$SSH_PID_FILE"
    log "ssh exited with code=$rc"

    [[ -f "$STOP_FLAG" ]] && { log "stop flag set; not restarting"; break; }

    log "restarting in ${backoff}s (auto-restart)"
    sleep "$backoff"
    if (( backoff < max_backoff )); then
      backoff=$(( backoff * 2 ))
      (( backoff > max_backoff )) && backoff=$max_backoff
    fi
  done
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

  # Hard rule: do NOT start if port is in use.
  if port_in_use; then
    kill_ssh_listeners_on_port
  fi
  if port_in_use; then
    show_port_listeners
    die "Port ${SOCKS_PORT}/TCP is in use. Stop the listener or change SOCKS_PORT."
  fi

  rm -f "$PID_FILE" "$STOP_FLAG" "$SSH_PID_FILE"

  nohup "$0" _run_loop >/dev/null 2>&1 &
  disown || true

  for _ in {1..40}; do
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

  local pid ssh_pid
  pid="$(get_pid)"
  ssh_pid="$(get_ssh_pid)"

  # Even if pidfile is missing, still try to clean the port.
  if [[ -z "$pid" ]]; then
    echo "Not running (no PID file)."
    kill_ssh_listeners_on_port
    if port_in_use; then
      show_port_listeners
      die "Port ${SOCKS_PORT}/TCP still in use."
    fi
    echo "Stopped."
    exit 0
  fi

  echo "Stopping (PID=$pid) ..."
  touch "$STOP_FLAG"

  # Kill child ssh first (frees the port faster)
  if [[ -n "$ssh_pid" ]]; then
    kill_pid_gracefully "$ssh_pid"
    rm -f "$SSH_PID_FILE"
  fi

  # Then kill supervisor
  kill_pid_gracefully "$pid"

  # Extra safety: kill orphan ssh listeners on the port
  kill_ssh_listeners_on_port

  rm -f "$PID_FILE" "$STOP_FLAG"

  # Verify
  if port_in_use; then
    show_port_listeners
    die "Stop finished, but port ${SOCKS_PORT}/TCP is still in use."
  fi

  echo "Stopped."
}

cmd_status() {
  local pid
  pid="$(get_pid)"
  if [[ -n "$pid" ]] && is_running_pid "$pid"; then
    echo "RUNNING (PID=$pid) — SOCKS5 on ${SOCKS_HOST}:${SOCKS_PORT}"
    if port_in_use; then
      show_port_listeners
    else
      echo "WARNING: supervisor running, but no listener on TCP/${SOCKS_PORT}."
    fi
    exit 0
  fi
  echo "STOPPED"
  if port_in_use; then
    echo "WARNING: STOPPED, but someone is still LISTENing on TCP/${SOCKS_PORT}."
    show_port_listeners
  fi
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
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  restart)  cmd_restart ;;
  logs)     cmd_logs ;;
  _run_loop) run_loop ;;
  *)
    cat <<EOF
Usage: $0 [start|stop|status|restart|logs]

Environment overrides (optional):
  SSH_HOST, SSH_USER, SSH_PORT
  SOCKS_HOST, SOCKS_PORT
  ALIVE_INTERVAL, ALIVE_COUNTMAX
  STATE_DIR
  KILL_SSH_LISTENERS_ON_PORT (default: 1)

Example:
  SSH_HOST=dark-horse SSH_USER=cowboy SSH_PORT=2222 \\
  SOCKS_PORT=1080 $0 start
EOF
    exit 2
    ;;
esac
