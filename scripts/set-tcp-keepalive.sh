#!/bin/bash
# set-tcp-keepalive.sh
#
# Sets aggressive TCP keepalive values to help maintain connections
# across VPN reconnects and network changes.
#
# Usage:
#   sudo ./set-tcp-keepalive.sh
#
# These settings reduce the time before TCP detects a dead connection,
# which helps applications recover faster when network paths change.

set -euo pipefail

# Configuration (values in milliseconds)
KEEPIDLE=30000      # Time before first keepalive probe (default: 7200000 = 2 hours)
KEEPINTVL=10000     # Interval between probes (default: 75000 = 75 seconds)
KEEPCNT=6           # Number of probes before giving up (default: 8)
ALWAYS_KEEPALIVE=1  # Enable keepalive on all TCP connections (default: 0)

echo "TCP Keepalive Configuration"
echo "==========================="
echo ""

# Detect OS
case "$(uname -s)" in
    Darwin)
        echo "Platform: macOS"
        echo ""
        echo "Current settings:"
        sysctl net.inet.tcp.keepidle net.inet.tcp.keepintvl net.inet.tcp.keepcnt net.inet.tcp.always_keepalive
        echo ""

        if [[ $EUID -ne 0 ]]; then
            echo "Note: Run with sudo to apply changes"
            exit 0
        fi

        echo "Applying new settings..."
        sysctl -w net.inet.tcp.keepidle=$KEEPIDLE
        sysctl -w net.inet.tcp.keepintvl=$KEEPINTVL
        sysctl -w net.inet.tcp.keepcnt=$KEEPCNT
        sysctl -w net.inet.tcp.always_keepalive=$ALWAYS_KEEPALIVE
        ;;

    Linux)
        echo "Platform: Linux"
        echo ""

        # Linux uses seconds, not milliseconds
        KEEPIDLE_SEC=$((KEEPIDLE / 1000))
        KEEPINTVL_SEC=$((KEEPINTVL / 1000))

        echo "Current settings:"
        sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
        echo ""

        if [[ $EUID -ne 0 ]]; then
            echo "Note: Run with sudo to apply changes"
            exit 0
        fi

        echo "Applying new settings..."
        sysctl -w net.ipv4.tcp_keepalive_time=$KEEPIDLE_SEC
        sysctl -w net.ipv4.tcp_keepalive_intvl=$KEEPINTVL_SEC
        sysctl -w net.ipv4.tcp_keepalive_probes=$KEEPCNT
        ;;

    *)
        echo "Unsupported platform: $(uname -s)"
        exit 1
        ;;
esac

echo ""
echo "New settings applied."
echo ""
echo "Note: These settings will reset on reboot."
echo "See examples/ for LaunchDaemon (macOS) or sysctl.d (Linux) configurations."
