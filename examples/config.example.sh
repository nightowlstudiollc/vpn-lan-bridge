#!/bin/bash
# VPN LAN Bridge Configuration
#
# Copy this file to config.sh in the repository root and edit with your values.
# Alternatively, set these as environment variables or pass as command-line arguments.

# ==============================================================================
# REQUIRED SETTINGS
# ==============================================================================

# Your computer's LAN IP address (the physical network interface, NOT the VPN)
# Find it with: ifconfig en0 | grep "inet "
# Example: 192.168.1.100, 10.0.15.68, 172.16.0.50
LOCAL_LAN_IP="192.168.1.100"

# The remote service you want to reach on your local network
# This is the IP or hostname of the machine running the service (e.g., Synergy server)
REMOTE_HOST="192.168.1.50"

# The port the remote service listens on
# Synergy/Barrier: 24800
# SMB: 445
# Postgres: 5432
REMOTE_PORT="24800"

# ==============================================================================
# OPTIONAL SETTINGS
# ==============================================================================

# Local port for the proxy to listen on (default: same as REMOTE_PORT)
# Change this if you need the proxy on a different port
# PROXY_PORT="24800"

# Local address to bind the proxy (default: 127.0.0.1)
# Use 0.0.0.0 to allow connections from other machines (not recommended)
# PROXY_HOST="127.0.0.1"

# ==============================================================================
# NOTES
# ==============================================================================
#
# How to find your LAN IP:
#   macOS:   ifconfig en0 | grep "inet "
#   Linux:   ip addr show eth0 | grep "inet "
#   Windows: ipconfig | findstr "IPv4"
#
# How to find the remote host IP:
#   If using mDNS/Bonjour: ping hostname.local
#   Or check the remote machine's network settings
#
# Common ports:
#   - Synergy/Barrier: 24800
#   - SMB/CIFS: 445
#   - SSH: 22
#   - HTTP: 80
#   - HTTPS: 443
#   - PostgreSQL: 5432
#   - MySQL: 3306
#   - Redis: 6379
