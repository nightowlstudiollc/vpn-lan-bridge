# Synergy/Barrier Setup Guide

This guide explains how to configure Synergy (or its fork, Barrier) to work with the VPN LAN Bridge.

## The Problem

When you connect to a corporate VPN, Synergy loses connection to your server because:

1. Your VPN routes private IP ranges through its tunnel
2. Your Synergy server is on a private IP (e.g., `192.168.1.50` or `10.0.15.32`)
3. Traffic to the server now goes through the VPN instead of your local network
4. The VPN either blocks this traffic or routes it incorrectly

**Symptoms:**
- Synergy client shows "Disconnected" or "Connecting..."
- Error: "WARNING: failed to connect to server: No route to host"
- Mouse and keyboard stop working on the server machine

## Solution Overview

The VPN LAN Bridge creates a local proxy that Synergy connects to. The proxy then forwards traffic to the actual server using your LAN interface, bypassing the VPN.

```
Synergy Client → 127.0.0.1:24800 → LAN Bridge → (via LAN) → Synergy Server
```

## Step-by-Step Setup

### 1. Identify Your Network Configuration

Find your client's LAN IP:
```bash
# macOS
ifconfig en0 | grep "inet "
# Example: inet 192.168.1.100 netmask 0xffffff00

# Linux
ip addr show eth0 | grep "inet "
```

Find your Synergy server's IP:
```bash
# If using mDNS/Bonjour
ping -c 1 your-server.local

# Or check Synergy server settings
```

Verify VPN is capturing the traffic:
```bash
route -n get 192.168.1.50
# If "interface: utun" appears, VPN is capturing it
```

### 2. Configure the LAN Bridge

Create `config.sh` in the repository root:

```bash
# Your client's LAN IP
LOCAL_LAN_IP="192.168.1.100"

# Your Synergy server's IP
REMOTE_HOST="192.168.1.50"

# Synergy port (default)
REMOTE_PORT="24800"
```

### 3. Test the Proxy

Start the proxy manually first:
```bash
./scripts/lan-bridge.py
```

You should see:
```
LAN Bridge started
  Listening on:    127.0.0.1:24800
  Forwarding to:   192.168.1.50:24800
  Via LAN IP:      192.168.1.100
```

### 4. Configure Synergy Client

The client needs to connect to `127.0.0.1` instead of the server's actual IP.

#### Synergy 3.x (Electron GUI)

1. Open Synergy settings
2. Find the server configuration
3. Change the server IP from `192.168.1.50` to `127.0.0.1`

**Or** modify the config file directly:

Edit `~/Library/Preferences/Synergy/local.json` (macOS) and find the `local_computers` section:

```json
"local_computers": {
    "your-client-id": "127.0.0.1",
    "server-id": "127.0.0.1"
}
```

#### Synergy 1.x / Barrier

Edit the client configuration to use `127.0.0.1` as the server address.

Command line:
```bash
synergyc 127.0.0.1
```

Or in the GUI, set server to `127.0.0.1`.

### 5. Restart Synergy

After changing the configuration:

```bash
# Kill existing client
pkill -f synergy-core  # or synergyc for older versions

# Synergy should auto-restart (if running as service)
# Or start manually
```

Check the connection:
```bash
# Synergy 3.x logs
tail -f ~/Library/Logs/Synergy/synergy.log

# Look for:
# NOTE: connecting to '127.0.0.1': 127.0.0.1:24800
# INFO: connected to secure socket
# NOTE: connected to server
```

### 6. Set Up Auto-Start

#### macOS

Copy and configure the LaunchAgent:
```bash
cp examples/com.vpn-lan-bridge.plist ~/Library/LaunchAgents/
# Edit paths in the file
nano ~/Library/LaunchAgents/com.vpn-lan-bridge.plist

# Load it
launchctl load ~/Library/LaunchAgents/com.vpn-lan-bridge.plist
```

#### Linux

Copy and configure the systemd service:
```bash
sudo cp examples/vpn-lan-bridge.service /etc/systemd/system/
# Edit paths in the file
sudo nano /etc/systemd/system/vpn-lan-bridge.service

sudo systemctl enable vpn-lan-bridge
sudo systemctl start vpn-lan-bridge
```

## Troubleshooting

### "Connection refused"

The proxy isn't running or isn't listening on port 24800.

```bash
# Check proxy is running
pgrep -fl lan-bridge

# Check port is open
nc -z 127.0.0.1 24800
```

### "No route to host" in proxy logs

The proxy can't reach the server via your LAN IP. Verify:

1. Your LAN IP is correct:
   ```bash
   ifconfig en0 | grep "inet "
   ```

2. You can reach the server when binding to LAN IP:
   ```bash
   # macOS
   ping -S 192.168.1.100 192.168.1.50

   # Linux
   ping -I 192.168.1.100 192.168.1.50
   ```

3. The server is actually running and accepting connections

### Synergy connects but immediately disconnects

Check for TLS/certificate issues:
```bash
tail -f ~/Library/Logs/Synergy/synergy.log | grep -i ssl
```

The proxy passes through TLS traffic transparently, but certificate fingerprints must match.

### Connection works but feels laggy

This is normal - traffic now goes through an extra hop. The latency added is minimal (< 1ms) but may be noticeable for fast mouse movements.

## Server-Side Notes

The Synergy **server** doesn't need any changes. It continues to listen on its normal IP address. Only the **client** configuration changes to point to the local proxy.

If your server also runs a VPN and needs to reach the client:
1. Set up the LAN Bridge on the server too
2. Or configure split tunneling on the server's VPN

## Multiple Servers

If you have multiple Synergy servers, you can run multiple proxy instances on different ports:

```bash
# Server 1 - port 24800
./scripts/lan-bridge.py --remote-host 192.168.1.50 --remote-port 24800

# Server 2 - port 24801
./scripts/lan-bridge.py --remote-host 192.168.1.51 --remote-port 24800 --proxy-port 24801
```

Then configure each Synergy client profile to use the appropriate local port.
