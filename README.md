# VPN LAN Bridge

**Maintain local network connectivity when your VPN captures LAN traffic**

## Prerequisites

- **Python 3.7 or higher** (standard library only, no additional packages)
- **Bash 3.2+** (for scripts)
- Basic understanding of networking (IP addresses, ports)

## The Problem

Many enterprise VPNs route private IP ranges (like `10.0.0.0/8` or `192.168.0.0/16`) through their tunnel for security purposes. When your home/office LAN uses IP addresses within these ranges, local network services become unreachable while connected to the VPN.

**Common symptoms:**

- KVM software (Synergy, Barrier, ShareMouse) stops working
- Network printers become inaccessible
- NAS/file shares disconnect
- Local development servers unreachable
- AirDrop/Bonjour services fail

**Example scenario:**

```
Home LAN:        10.0.15.0/24
VPN routes:      10.0.0.0/8 → tunnel
Result:          All 10.x.x.x traffic goes through VPN, including your LAN
```

## The Solution

This toolkit provides a **TCP proxy** that binds to your physical network interface, bypassing VPN routing for specific local services. Traffic flows through your LAN adapter directly instead of being captured by the VPN tunnel.

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Your Computer                               │
│  ┌──────────────┐    ┌─────────────────┐    ┌───────────────────┐   │
│  │   Synergy    │───▶│  LAN Bridge     │───▶│ Physical NIC      │   │
│  │   Client     │    │  (127.0.0.1)    │    │ (binds to LAN IP) │   │
│  └──────────────┘    └─────────────────┘    └─────────┬─────────┘   │
│                                                        │             │
│  ┌──────────────┐                                      │             │
│  │ VPN Tunnel   │◀─── (bypassed for proxied traffic)   │             │
│  │   (utun)     │                                      │             │
│  └──────────────┘                                      │             │
└────────────────────────────────────────────────────────┼─────────────┘
                                                         │
                                                         ▼
                                              ┌─────────────────────┐
                                              │   Local Service     │
                                              │  (Synergy Server)   │
                                              │    10.0.15.32       │
                                              └─────────────────────┘
```

## Quick Start

### 1. Verify Python Version

```bash
python3 --version  # Must be 3.7 or higher
```

If you need to upgrade Python:

- **macOS**: `brew install python3`
- **Linux**: Use your package manager (apt, yum, etc.)

### 2. Identify Your Network Configuration

```bash
# Find your local LAN IP
ifconfig en0 | grep "inet "
# Example output: inet 192.168.1.100 netmask 0xffffff00

# Find the service you want to reach
ping -c 1 your-server.local
# Note the IP address

# Check if VPN is capturing the traffic
route -n get 192.168.1.50
# If "interface: utun" appears, the VPN is capturing it
```

### 3. Configure the Proxy

Copy the example configuration:

```bash
cp examples/config.example.sh config.sh
```

Edit `config.sh` with your values (key=value format, no spaces around `=`):

```bash
# Your computer's LAN IP (the physical interface, not VPN)
LOCAL_LAN_IP=192.168.1.100

# The service you want to reach
REMOTE_HOST=192.168.1.50
REMOTE_PORT=24800

# Local proxy port (application connects here)
PROXY_PORT=24800
```

**Important**: The config file uses a strict key=value format:

- No spaces around the `=` sign
- Lines starting with `#` are comments and ignored
- Empty lines are ignored
- Invalid lines will generate warnings but won't stop execution

### 4. Start the Proxy

```bash
./scripts/lan-bridge.py
```

### 4. Configure Your Application

Point your application to `127.0.0.1:24800` instead of the remote IP.

## Detailed Setup

### For Synergy/Barrier

See [docs/synergy-setup.md](docs/synergy-setup.md)

### For Other TCP Services

The proxy works with any TCP-based service:

- File shares (SMB on port 445)
- Printers (IPP on port 631)
- Development servers
- Database connections

## Installation

### macOS

```bash
# Clone repository
git clone https://github.com/yourusername/vpn-lan-bridge.git
cd vpn-lan-bridge

# Copy and edit configuration
cp examples/config.example.sh config.sh
nano config.sh

# Install LaunchAgent for auto-start
cp examples/com.vpn-lan-bridge.plist ~/Library/LaunchAgents/
# Edit the plist to match your paths
launchctl load ~/Library/LaunchAgents/com.vpn-lan-bridge.plist
```

### Linux

```bash
# Clone repository
git clone https://github.com/yourusername/vpn-lan-bridge.git
cd vpn-lan-bridge

# Copy and edit configuration
cp examples/config.example.sh config.sh
nano config.sh

# Install systemd service for auto-start
sudo cp examples/vpn-lan-bridge.service /etc/systemd/system/
sudo systemctl enable vpn-lan-bridge
sudo systemctl start vpn-lan-bridge
```

## Additional Tools

### GlobalProtect VPN Control (macOS)

AppleScript helpers to toggle VPN connection:

```bash
# Toggle VPN on/off
osascript scripts/globalprotect/gp-toggle.scpt

# Explicit connect/disconnect
osascript scripts/globalprotect/gp-connect.scpt
osascript scripts/globalprotect/gp-disconnect.scpt
```

### TCP Keepalive Optimization

Aggressive keepalive settings help maintain connections across VPN reconnects:

```bash
# macOS - apply immediately
sudo ./scripts/set-tcp-keepalive.sh

# Install for persistence across reboots
sudo cp examples/com.tcp-keepalive.plist /Library/LaunchDaemons/
```

### Connection Watchdog

Monitor your service and restart the proxy if needed:

```bash
./scripts/watchdog.sh
```

## How It Works

### The Routing Problem

When you connect to a VPN, it typically:

1. Creates a virtual network interface (e.g., `utun0`)
2. Adds routes that direct traffic through this interface
3. For "full tunnel" VPNs, this includes all private IP ranges

```bash
# Example routing table with VPN connected
$ netstat -rn | grep "10\."
10.0.0.0/8        10.153.43.39      UGSc    utun0    # VPN captures all 10.x.x.x
```

Your LAN (`10.0.15.0/24`) falls within `10.0.0.0/8`, so all local traffic gets routed through the VPN tunnel.

### The Proxy Solution

The proxy works by:

1. **Listening locally** on `127.0.0.1:PORT`
2. **Binding outbound connections** to your physical LAN IP
3. **Forwarding traffic** between local and remote endpoints

```python
# Key mechanism - bind to specific source IP before connecting
remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
remote_sock.bind((LOCAL_LAN_IP, 0))  # Bind to LAN interface
remote_sock.connect((REMOTE_HOST, REMOTE_PORT))  # Connect via LAN
```

When the socket is bound to the LAN IP, the OS routes the traffic through the physical interface rather than the VPN tunnel.

### Why This Works

- Binding to a specific source IP forces the OS to use the interface that owns that IP
- The VPN tunnel interface has its own IP (e.g., `10.153.43.39`), not your LAN IP
- Traffic originating from your LAN IP bypasses VPN routing rules

## Troubleshooting

### Verify LAN Connectivity

```bash
# Test if you can reach the server via LAN (bypassing VPN)
ping -S 192.168.1.100 192.168.1.50

# If this works but normal ping fails, the proxy solution will help
ping 192.168.1.50  # Fails - goes through VPN
```

### Proxy Not Connecting

1. Check the proxy is running:

   ```bash
   pgrep -fl lan-bridge
   ```

2. Check the proxy log:

   ```bash
   tail -f ~/log/lan-bridge.log
   ```

3. Verify your LAN IP is correct:

   ```bash
   ifconfig en0 | grep "inet "
   ```

### Application Still Not Working

1. Verify application is connecting to `127.0.0.1`, not the remote IP
2. Check firewall isn't blocking local connections
3. Ensure the remote service is actually running

### VPN Reconnect Breaks Everything

The TCP keepalive settings help, but you may need to:

1. Restart the proxy after VPN reconnects
2. Use the watchdog script for automatic recovery

## Tested VPN Clients

| VPN Client | OS | Status |
|------------|-----|--------|
| GlobalProtect | macOS | Working (requires Python 3.7+) |
| GlobalProtect | Windows | Untested (requires Python 3.7+) |
| Cisco AnyConnect | macOS | Should work (requires Python 3.7+) |
| OpenVPN | Linux | Should work (requires Python 3.7+) |

## Tested Applications

| Application | Default Port | Status |
|-------------|--------------|--------|
| Synergy | 24800 | Working |
| Barrier | 24800 | Should work |
| SMB/CIFS | 445 | Untested |
| Postgres | 5432 | Should work |

## Limitations

1. Only TCP services (no UDP)
2. Requires continuous VPN connection
3. For "full tunnel" VPNs, this includes all private IP ranges
4. TCP keepalive helps, but long-idle connections may still drop
5. Requires Python 3.7 or higher (check with `python3 --version`)

## Contributing

Contributions welcome! Please test with your VPN/application combination and submit a PR with your findings.

## License

MIT License - See [LICENSE](LICENSE)

## Acknowledgments

- Inspired by the frustration of "No route to host" errors
- Thanks to the Synergy/Barrier communities for documenting VPN issues
