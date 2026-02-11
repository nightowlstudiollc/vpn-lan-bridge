# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VPN LAN Bridge is a TCP proxy that maintains local network connectivity when VPN software routes LAN traffic through its tunnel. The tool solves the "No route to host" problem for services like KVM software (Synergy/Barrier), printers, and development servers when connected to corporate VPNs.

**Core Problem**: Enterprise VPNs often route private IP ranges (10.0.0.0/8, 192.168.0.0/16) through their tunnel. When your LAN uses IPs in these ranges, local services become unreachable.

**Solution**: A Python TCP proxy that binds outbound connections to your physical LAN IP (`socket.bind()`), forcing traffic through the local interface instead of the VPN tunnel.

## Architecture

### Component Overview

```
Application        TCP Proxy           Target Service
(client)          (lan-bridge.py)      (LAN device)
    │                   │                    │
    │  1. Connect       │                    │
    │  127.0.0.1:24800  │                    │
    ├──────────────────>│                    │
    │                   │ 2. Bind to LAN IP  │
    │                   │    192.168.1.100   │
    │                   │                    │
    │                   │ 3. Connect to      │
    │                   │    192.168.1.50    │
    │                   ├───────────────────>│
    │                   │                    │
    │ 4. Bidirectional traffic forwarding   │
    │<────────────────────────────────────────>│
```

### Key Mechanism

The proxy forces routing through the correct interface using `socket.bind()`:

```python
remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
remote_sock.bind((self.local_lan_ip, 0))  # Bind to physical LAN interface
remote_sock.connect((self.remote_host, self.remote_port))
```

This is **routing at the socket level**, not at the network routing table level. The VPN's routes remain unchanged, but connections are bound to a specific source IP that only exists on the physical interface.

### Core Components

1. **`lan-bridge.py`**: Main TCP proxy (Python 3, threading model)
   - Accepts connections on `PROXY_HOST:PROXY_PORT` (default: 127.0.0.1:24800)
   - Binds outbound connections to `LOCAL_LAN_IP` (your physical interface IP)
   - Forwards traffic bidirectionally using separate reader threads

2. **`watchdog.sh`**: Monitor and auto-restart proxy
   - Checks proxy process health (PID file-based)
   - Validates remote service connectivity
   - Restart cooldown (120s) to prevent flapping
   - Can run as foreground daemon, cron job, or one-shot

3. **`diagnose.sh`**: Network diagnostic tool
   - Lists all interfaces and IPs (en0, utun interfaces)
   - Shows routing table with VPN routes highlighted
   - Tests route to target host
   - Validates TCP connectivity

4. **GlobalProtect Scripts** (`scripts/globalprotect/*.scpt`): AppleScript automation for macOS GlobalProtect VPN
   - `gp-connect.scpt`, `gp-disconnect.scpt`, `gp-toggle.scpt`
   - Uses UI automation (requires Accessibility permissions)

5. **`set-tcp-keepalive.sh`**: System-level TCP keepalive tuning
   - macOS: `sysctl net.inet.tcp.*`
   - Linux: `/proc/sys/net/ipv4/tcp_keepalive_*`
   - Non-persistent (resets on reboot unless configured via LaunchDaemon/sysctl.d)

## Configuration

All scripts load configuration from `config.sh` in repository root (gitignored). Copy from `examples/config.example.sh`:

```bash
# Required settings
LOCAL_LAN_IP=192.168.1.100        # Your computer's physical LAN IP
REMOTE_HOST=192.168.1.50          # Target LAN device
REMOTE_PORT=24800                 # Target service port

# Proxy settings (optional)
PROXY_HOST=127.0.0.1              # Proxy bind address
PROXY_PORT=24800                  # Proxy listen port
```

**Configuration Format**: Simple KEY=value pairs (not executed as shell code). See `examples/config.example.sh` for supported syntax and limitations.

### Security Note

The config file uses simple key-value parsing and is **not executed as shell code**. Command substitution (e.g., `$(ifconfig en0)`) and variable expansion (e.g., `${HOME}`) are treated as literal strings. For dynamic configuration, use environment variables or command-line arguments.

**Finding your LAN IP**:

```bash
./scripts/diagnose.sh              # Comprehensive network info
ifconfig en0 | grep "inet "        # macOS physical interface
ip addr show                        # Linux
```

## Common Commands

### Running the Proxy

```bash
# One-time execution (uses config.sh in repo root)
./scripts/lan-bridge.py

# With explicit configuration
./scripts/lan-bridge.py \
  --lan-ip 192.168.1.100 \
  --remote-host 192.168.1.50 \
  --remote-port 24800

# Alternative: Set environment variables
export LAN_BRIDGE_LOCAL_IP=192.168.1.100
export LAN_BRIDGE_REMOTE_HOST=192.168.1.50
export LAN_BRIDGE_REMOTE_PORT=24800
./scripts/lan-bridge.py

# Custom config file location
./scripts/lan-bridge.py --config /path/to/config.sh
```

### Monitoring and Maintenance

```bash
# Network diagnostics (shows interfaces, routes, connectivity)
./scripts/diagnose.sh
./scripts/diagnose.sh 192.168.1.50  # Test specific host

# Watchdog monitoring
./scripts/watchdog.sh                # One-time check
./scripts/watchdog.sh --daemon       # Run continuously (foreground; use & or nohup to background)
./scripts/watchdog.sh --status       # Current status

# Install as cron job (checks every 5 minutes)
./scripts/watchdog.sh --install-cron
```

### System Configuration

```bash
# Set aggressive TCP keepalive (requires sudo)
sudo ./scripts/set-tcp-keepalive.sh

# VPN automation (macOS GlobalProtect)
osascript scripts/globalprotect/gp-connect.scpt
osascript scripts/globalprotect/gp-disconnect.scpt
osascript scripts/globalprotect/gp-toggle.scpt
```

### Persistent Deployment

Examples provided for systemd (Linux) and launchd (macOS):

```bash
# Linux (systemd)
cp examples/vpn-lan-bridge.service /etc/systemd/system/
systemctl enable --now vpn-lan-bridge
systemctl status vpn-lan-bridge

# macOS (launchd)
cp examples/com.vpn-lan-bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.vpn-lan-bridge.plist
launchctl list | grep vpn-lan-bridge

# TCP keepalive persistence
# Linux: cp examples/99-tcp-keepalive.conf /etc/sysctl.d/
# macOS: cp examples/com.tcp-keepalive.plist /Library/LaunchDaemons/
```

## Technical Details

### Threading Model

- **Main thread**: Accepts incoming connections, spawns handler thread per connection
- **Handler thread per connection**: Creates two reader threads (client→remote, remote→client)
- **Reader threads**: Relay data in 8KB chunks, set thread names for debugging

### Resource Management

- **Thread cleanup**: Dead threads are removed from tracking every 100 connections or on accept timeout
- **Graceful shutdown**: Waits up to 5 seconds per active connection on SIGTERM/SIGINT
- **PID file**: Written to `/tmp/lan-bridge-{port}.pid` for watchdog reliability

### Error Handling

The proxy provides diagnostic error messages for common failures:

- `Connection refused`: Target service not running
- `Connection timed out`: Target host unreachable (network issue)
- `No route to host`: **Most likely cause** - VPN is routing LAN traffic, verify `LOCAL_LAN_IP`
- `Address already in use`: Another proxy instance running or port conflict

### Port Selection

Common service ports to proxy:

- Synergy/Barrier: 24800
- SSH: 22
- HTTP: 80, HTTPS: 443
- PostgreSQL: 5432, MySQL: 3306
- Redis: 6379

### Limitations

1. **TCP-only**: Does not support UDP (Bonjour, mDNS, AirDrop)
2. **One service per proxy**: Each `REMOTE_HOST:REMOTE_PORT` requires separate proxy instance
3. **Client must support changing server address**: Application must connect to `127.0.0.1` instead of actual LAN IP
4. **VPN-specific behavior**: Works with "full tunnel" VPNs. Split-tunnel VPNs may not have this problem.

## Development Notes

### Shell Script Standards

All shell scripts follow these conventions:

- Bash 5.x compatible (`set -euo pipefail`)
- Must pass shellcheck without errors
- Functions use lowercase_with_underscores
- Global variables use UPPERCASE_WITH_UNDERSCORES

### Python Code

- Python 3.7+ required (minimum tested version)
- Standard library only (socket, threading, signal, argparse, logging, ipaddress)
- Logging levels: DEBUG (connection details), INFO (lifecycle), WARNING (recoverable), ERROR (fatal)
- Version available: `./scripts/lan-bridge.py --version`

### Testing Strategy

1. **Network diagnostics first**: Run `./scripts/diagnose.sh` to verify problem exists
2. **Manual proxy test**: Run proxy manually before setting up automation
3. **Watchdog validation**: Test watchdog before enabling persistent service
4. **VPN reconnect testing**: Verify proxy survives VPN disconnect/reconnect cycles

### Common Pitfalls

1. **Wrong LAN IP**: Using VPN tunnel IP (utun interface) instead of physical interface (en0)
2. **Client configuration**: Forgetting to update application to connect to proxy (127.0.0.1)
3. **Firewall**: Target host firewall blocking connections from your IP
4. **Port conflicts**: Another service already listening on `PROXY_PORT`
5. **Permissions**: GlobalProtect scripts require Accessibility permissions in System Settings

## Repository Structure

```
vpn-lan-bridge/
├── scripts/
│   ├── lan-bridge.py           # Main TCP proxy
│   ├── watchdog.sh             # Monitoring daemon
│   ├── diagnose.sh             # Network diagnostic tool
│   ├── set-tcp-keepalive.sh    # System TCP tuning
│   └── globalprotect/          # VPN automation (macOS)
│       ├── gp-connect.scpt
│       ├── gp-disconnect.scpt
│       └── gp-toggle.scpt
├── examples/
│   ├── config.example.sh       # Configuration template
│   ├── vpn-lan-bridge.service  # systemd unit (Linux)
│   ├── com.vpn-lan-bridge.plist # launchd plist (macOS)
│   ├── 99-tcp-keepalive.conf   # sysctl config (Linux)
│   └── com.tcp-keepalive.plist # LaunchDaemon (macOS)
├── docs/
│   ├── how-it-works.md         # Technical explanation
│   └── synergy-setup.md        # Synergy-specific guide
├── config.sh                   # User configuration (gitignored)
└── README.md                   # User-facing documentation
```

## Documentation References

- **Technical details**: `docs/how-it-works.md` - Routing explanation, socket binding mechanics
- **Synergy setup**: `docs/synergy-setup.md` - Step-by-step KVM software configuration
- **README.md**: User-facing setup guide and troubleshooting
