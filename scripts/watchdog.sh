#!/bin/bash
# watchdog.sh
#
# Monitors the LAN bridge proxy and remote service connectivity.
# Restarts the proxy if it's not running or if the remote service becomes unreachable.
#
# Compatible with bash 3.2+ (works with macOS system bash)
# Optional: flock for better locking (brew install flock on macOS)
#
# Usage:
#   ./watchdog.sh                    # Run once
#   ./watchdog.sh --daemon           # Run continuously
#   ./watchdog.sh --install-cron     # Install cron job
#
# Configuration:
#   Edit config.sh or set environment variables

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"

# Use platform-appropriate log directory
if [[ "$(uname)" == "Darwin" ]]; then
  LOG_DIR="${LOG_DIR:-${HOME}/Library/Logs/vpn-lan-bridge}"
else
  LOG_DIR="${LOG_DIR:-${HOME}/.local/log/vpn-lan-bridge}"
fi
LOG_FILE="${LOG_DIR}/watchdog.log"
LOCK_FILE="/tmp/lan-bridge-watchdog.lock"
COOLDOWN_FILE="/tmp/lan-bridge-watchdog-cooldown"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-120}"
DAEMON_INTERVAL="${DAEMON_INTERVAL:-60}"

# Try to acquire lock using best available method
acquire_lock() {
  local lockfile="$1"

  # Method 1: Try flock (most reliable, atomic, auto-cleanup)
  if command -v flock >/dev/null 2>&1; then
    exec 200>"${lockfile}"
    if ! flock -n 200; then
      # Another instance is running
      return 1
    fi
    echo $$ >&200
    # Lock held on fd 200 until process exits
    return 0
  fi

  # Method 2: Fallback to noclobber (atomic create, manual cleanup)
  (
    set -o noclobber
    if echo $$ >"${lockfile}" 2>/dev/null; then
      # We created the file, we have the lock
      exit 0
    else
      # File exists, check if process is still running
      if [[ -f "${lockfile}" ]]; then
        local pid
        pid=$(cat "${lockfile}" 2>/dev/null || echo "")
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
          # Process still running
          exit 1
        else
          # Stale lock file, remove and try again
          rm -f "${lockfile}"
          exit 2
        fi
      fi
      exit 1
    fi
  )
  local result=$?

  if [[ ${result} -eq 0 ]]; then
    # We got the lock, set up cleanup
    trap 'rm -f "$lockfile"' EXIT INT TERM HUP
    return 0
  fi

  return "${result}"
}

# Create log directory
mkdir -p "${LOG_DIR}"

# Safe config loading - parse KEY=value only (no shell execution)
load_config_safe() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip comments
    line="${line%%#*}"
    # Trim whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # Skip empty lines
    [[ -z "$line" ]] && continue
    # Skip lines without =
    [[ "$line" != *=* ]] && continue

    # Split on first =
    key="${line%%=*}"
    value="${line#*=}"

    # Strip 'export' prefix if present
    key="${key#export }"
    key="${key#"${key%%[![:space:]]*}"}"

    # Strip quotes from value
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"

    # Export the variable
    export "$key=$value"
  done <"$config_file"
}

# Load configuration safely (no shell execution)
if [[ -f "${REPO_DIR}/config.sh" ]]; then
  load_config_safe "${REPO_DIR}/config.sh"
elif [[ -f "${HOME}/.config/lan-bridge/config.sh" ]]; then
  load_config_safe "${HOME}/.config/lan-bridge/config.sh"
fi

# Validate configuration
LOCAL_LAN_IP="${LOCAL_LAN_IP:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PORT="${REMOTE_PORT:-}"
PROXY_PORT="${PROXY_PORT:-${REMOTE_PORT}}"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

check_config() {
  if [[ -z "${LOCAL_LAN_IP}" || -z "${REMOTE_HOST}" || -z "${REMOTE_PORT}" ]]; then
    log "ERROR: Missing configuration. Set LOCAL_LAN_IP, REMOTE_HOST, REMOTE_PORT"
    exit 1
  fi
}

check_proxy_running() {
  pgrep -f "lan-bridge.py" >/dev/null 2>&1
}

check_proxy_port() {
  nc -z -w 2 "${PROXY_HOST}" "${PROXY_PORT}" 2>/dev/null
}

check_remote_via_lan() {
  # Test connectivity to remote service via LAN IP (bypassing VPN)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ping -c 1 -W 2 -S "${LOCAL_LAN_IP}" "${REMOTE_HOST}" >/dev/null 2>&1
  else
    ping -c 1 -W 2 -I "${LOCAL_LAN_IP}" "${REMOTE_HOST}" >/dev/null 2>&1
  fi
}

in_cooldown() {
  if [[ -f "${COOLDOWN_FILE}" ]]; then
    local last_action
    last_action=$(cat "${COOLDOWN_FILE}" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local elapsed=$((now - last_action))
    [[ ${elapsed} -lt ${COOLDOWN_SECONDS} ]]
  else
    return 1
  fi
}

set_cooldown() {
  date +%s >"${COOLDOWN_FILE}"
}

start_proxy() {
  log "Starting LAN bridge proxy..."

  # Check PID file first (more reliable than pgrep)
  local pid_file="/tmp/lan-bridge-${PROXY_PORT}.pid"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid=$(cat "${pid_file}" 2>/dev/null || echo "")
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      log "Proxy already running (PID: ${pid})"
      return 0
    fi
  fi

  python3 "${SCRIPT_DIR}/lan-bridge.py" &
  sleep 2

  if check_proxy_running; then
    log "Proxy started successfully"
    set_cooldown
  else
    log "ERROR: Failed to start proxy"
    return 1
  fi
}

run_check() {
  acquire_lock "${LOCK_FILE}"
  local lock_result=$?

  if [[ ${lock_result} -eq 1 ]]; then
    # Another instance is running
    return 0
  elif [[ ${lock_result} -eq 2 ]]; then
    # Stale lock removed, retry once
    if ! acquire_lock "${LOCK_FILE}"; then
      return 0
    fi
  fi

  # We have the lock, proceed with checks
  log "Starting watchdog check"

  # Check proxy is running
  if ! check_proxy_running; then
    log "Proxy not running"
    if in_cooldown; then
      log "In cooldown period, skipping restart"
      return 0
    fi
    start_proxy
    return 0
  fi

  # Check proxy port is listening
  if ! check_proxy_port; then
    log "Proxy port not responding"
    if in_cooldown; then
      log "In cooldown period, skipping restart"
      return 0
    fi
    pkill -f "lan-bridge.py" 2>/dev/null || true
    sleep 1
    start_proxy
    return 0
  fi

  # Check remote service is reachable via LAN
  if ! check_remote_via_lan; then
    log "Remote service unreachable via LAN (may be server-side issue)"
  fi
}

run_daemon() {
  log "Starting watchdog daemon (interval: ${DAEMON_INTERVAL}s)"
  while true; do
    run_check
    sleep "${DAEMON_INTERVAL}"
  done
}

install_cron() {
  local cron_entry="*/5 * * * * ${SCRIPT_DIR}/watchdog.sh >> ${LOG_FILE} 2>&1"

  if crontab -l 2>/dev/null | grep -q "lan-bridge"; then
    echo "Cron job already exists"
    crontab -l | grep "lan-bridge"
  else
    (
      crontab -l 2>/dev/null
      echo "${cron_entry}"
    ) | crontab -
    echo "Installed cron job (runs every 5 minutes):"
    echo "  ${cron_entry}"
  fi
}

show_status() {
  echo "LAN Bridge Status"
  echo "================="
  echo ""
  echo "Configuration:"
  echo "  LOCAL_LAN_IP:  ${LOCAL_LAN_IP:-not set}"
  echo "  REMOTE_HOST:   ${REMOTE_HOST:-not set}"
  echo "  REMOTE_PORT:   ${REMOTE_PORT:-not set}"
  echo "  PROXY_HOST:    ${PROXY_HOST}"
  echo "  PROXY_PORT:    ${PROXY_PORT:-not set}"
  echo ""
  echo "Status:"

  if check_proxy_running; then
    echo "  Proxy process: Running ($(pgrep -f lan-bridge.py))"
  else
    echo "  Proxy process: Not running"
  fi

  if [[ -n "${PROXY_PORT}" ]] && check_proxy_port; then
    echo "  Proxy port:    Listening"
  else
    echo "  Proxy port:    Not responding"
  fi

  if [[ -n "${LOCAL_LAN_IP}" && -n "${REMOTE_HOST}" ]]; then
    if check_remote_via_lan; then
      echo "  Remote (LAN):  Reachable"
    else
      echo "  Remote (LAN):  Unreachable"
    fi
  fi
}

# Parse arguments
case "${1:-}" in
  --daemon | -d)
    check_config
    run_daemon
    ;;
  --install-cron)
    check_config
    install_cron
    ;;
  --status | -s)
    show_status
    ;;
  --help | -h)
    echo "Usage: $0 [--daemon|--install-cron|--status|--help]"
    echo ""
    echo "Options:"
    echo "  --daemon, -d       Run continuously"
    echo "  --install-cron     Install cron job for periodic checks"
    echo "  --status, -s       Show current status"
    echo "  --help, -h         Show this help"
    echo ""
    echo "With no options, runs a single check."
    ;;
  *)
    check_config
    run_check
    ;;
esac
