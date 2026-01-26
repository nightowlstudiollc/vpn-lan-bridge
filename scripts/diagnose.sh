#!/bin/bash
# diagnose.sh
#
# Network diagnostic tool to help identify VPN routing issues.
# Run this to understand your network configuration and verify the problem.
#
# Usage:
#   ./diagnose.sh
#   ./diagnose.sh 192.168.1.50    # Diagnose connectivity to specific host

set -euo pipefail

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

TARGET_HOST="${1:-}"

echo "========================================"
echo "  VPN LAN Bridge - Network Diagnostic"
echo "========================================"
echo ""

# Detect OS
OS="$(uname -s)"
echo "Operating System: $OS"
echo ""

# List network interfaces
echo "Network Interfaces:"
echo "-------------------"
case "$OS" in
  Darwin)
    # macOS
    for iface in en0 en1 en7 utun0 utun1 utun2 utun3 utun4; do
      ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")
      if [[ -n "$ip" ]]; then
        echo "  $iface: $ip"
      fi
    done
    ;;
  Linux)
    ip -4 addr show | grep -E "inet " | awk '{print "  " $NF ": " $2}'
    ;;
esac
echo ""

# Show VPN status
echo "VPN Interfaces:"
echo "---------------"
case "$OS" in
  Darwin)
    ifconfig | grep -E "^utun|^tun|^tap" | cut -d: -f1 | while read -r iface; do
      ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "no IP")
      echo "  $iface: $ip"
    done
    if ! ifconfig | grep -qE "^utun|^tun|^tap"; then
      echo "  (no VPN interfaces detected)"
    fi
    ;;
  Linux)
    ip link show | grep -E "tun|tap" | awk -F: '{print "  " $2}'
    ;;
esac
echo ""

# Show routing table (key routes)
echo "Key Routes:"
echo "-----------"
case "$OS" in
  Darwin)
    netstat -rn 2>/dev/null | grep -E "^(default|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)" | head -20
    ;;
  Linux)
    ip route | grep -E "^(default|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)" | head -20
    ;;
esac
echo ""

# If target host specified, diagnose connectivity
if [[ -n "$TARGET_HOST" ]]; then
  echo "Target Host Analysis: $TARGET_HOST"
  echo "------------------------------------"

  # Check route to target
  echo ""
  echo "Route to $TARGET_HOST:"
  case "$OS" in
    Darwin)
      route -n get "$TARGET_HOST" 2>/dev/null | grep -E "(interface|gateway):" || echo "  Route lookup failed"
      ;;
    Linux)
      ip route get "$TARGET_HOST" 2>/dev/null || echo "  Route lookup failed"
      ;;
  esac

  # Check if route goes through VPN
  echo ""
  route_iface=$(route -n get "$TARGET_HOST" 2>/dev/null | grep "interface:" | awk '{print $2}' || echo "")
  if [[ "$route_iface" == utun* || "$route_iface" == tun* ]]; then
    echo "⚠️  WARNING: Traffic to $TARGET_HOST is routed through VPN ($route_iface)"
    echo "   This is likely the cause of connectivity issues."
  elif [[ -n "$route_iface" ]]; then
    echo "✓  Traffic to $TARGET_HOST goes through $route_iface (physical interface)"
  fi

  # Try to find local LAN IP
  echo ""
  echo "Suggested LOCAL_LAN_IP:"
  case "$OS" in
    Darwin)
      for iface in en0 en1 en7; do
        ip=$(ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")
        if [[ -n "$ip" ]]; then
          echo "  $ip (from $iface)"
        fi
      done
      ;;
    Linux)
      ip -4 addr show | grep -v "127.0.0.1" | grep "inet " | awk '{print "  " $2 " (from " $NF ")"}'
      ;;
  esac

  # Test direct ping vs bound ping
  echo ""
  echo "Connectivity Tests:"

  # Get first LAN IP for testing
  case "$OS" in
    Darwin)
      lan_ip=$(ifconfig en0 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")
      ;;
    Linux)
      lan_ip=$(ip -4 addr show | grep -v "127.0.0.1" | grep "inet " | head -1 | awk '{print $2}' | cut -d/ -f1)
      ;;
  esac

  echo ""
  echo "  Normal ping (uses routing table):"
  if ping -c 1 -W 2 "$TARGET_HOST" >/dev/null 2>&1; then
    echo "    ✓ Success"
  else
    echo "    ✗ Failed (VPN may be blocking)"
  fi

  if [[ -n "$lan_ip" ]]; then
    echo ""
    echo "  Ping via LAN IP ($lan_ip):"
    case "$OS" in
      Darwin)
        if ping -c 1 -W 2 -S "$lan_ip" "$TARGET_HOST" >/dev/null 2>&1; then
          echo "    ✓ Success - LAN Bridge should work!"
        else
          echo "    ✗ Failed - host may be unreachable or firewall blocking"
        fi
        ;;
      Linux)
        if ping -c 1 -W 2 -I "$lan_ip" "$TARGET_HOST" >/dev/null 2>&1; then
          echo "    ✓ Success - LAN Bridge should work!"
        else
          echo "    ✗ Failed - host may be unreachable or firewall blocking"
        fi
        ;;
    esac
  fi

  # Test port connectivity (if nc available)
  echo ""
  # Try to load REMOTE_PORT from config.sh if it exists (safe parsing, no execution)
  if [[ -f "config.sh" ]]; then
    load_config_safe "config.sh" 2>/dev/null || true
  fi
  REMOTE_PORT="${REMOTE_PORT:-24800}"
  echo "  Port check (${REMOTE_PORT}):"
  if nc -z -w 2 "$TARGET_HOST" "${REMOTE_PORT}" 2>/dev/null; then
    echo "    ✓ Port ${REMOTE_PORT} is open"
  else
    echo "    ✗ Port ${REMOTE_PORT} is closed or unreachable"
  fi
else
  echo "Tip: Run with a target IP to diagnose connectivity:"
  echo "  $0 192.168.1.50"
fi

echo ""
echo "========================================"
echo "  Diagnostic Complete"
echo "========================================"
