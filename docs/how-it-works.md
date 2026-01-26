# How VPN LAN Bridge Works

This document explains the technical details of why corporate VPNs break local network access and how this tool solves the problem.

## Understanding the Problem

### IP Routing Basics

When your computer sends traffic to an IP address, the operating system consults the **routing table** to decide which network interface to use:

```bash
$ netstat -rn
Destination        Gateway            Interface
default            192.168.1.1        en0        # Normal internet traffic
192.168.1.0/24     link#1             en0        # Local network
10.0.0.0/8         10.153.43.39       utun0      # VPN-routed traffic
```

Each route has:
- **Destination**: IP range this route applies to
- **Gateway**: Where to send the traffic
- **Interface**: Physical or virtual network adapter

### What VPNs Do

When you connect to a corporate VPN, the VPN client:

1. **Creates a virtual interface** (e.g., `utun0`, `tun0`, `tap0`)
2. **Adds routes** that direct traffic through this interface
3. **May override the default route** (full tunnel VPN)

For security, many corporate VPNs route **all private IP ranges** through the tunnel:

```
10.0.0.0/8         → VPN tunnel
172.16.0.0/12      → VPN tunnel
192.168.0.0/16     → VPN tunnel
```

This is called a **"no split tunnel"** configuration and is common in enterprise environments.

### The Collision

Your home network likely uses one of these private ranges:
- `192.168.1.0/24` (most common)
- `10.0.0.0/24`
- `172.16.0.0/24`

When the VPN adds a route for `192.168.0.0/16`, your local network (`192.168.1.0/24`) is now routed through the VPN:

```
Before VPN:
  192.168.1.50 → en0 (local) → Synergy Server ✓

After VPN:
  192.168.1.50 → utun0 (VPN) → Corporate Network → ??? ✗
```

The corporate network doesn't know about your Synergy server, so the connection fails.

## The Solution

### Source-Based Routing

The key insight is that routing decisions are based on the **destination** IP, but we can influence which interface is used by specifying the **source** IP.

When you bind a socket to a specific source IP address, the OS routes the connection through the interface that owns that IP:

```python
# Normal connection (uses routing table)
sock.connect(('192.168.1.50', 24800))
# → Routes through VPN because of 192.168.0.0/16 route

# Connection bound to LAN IP
sock.bind(('192.168.1.100', 0))
sock.connect(('192.168.1.50', 24800))
# → Routes through en0 because 192.168.1.100 is on en0
```

### The Proxy Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Your Computer                              │
│                                                                   │
│  ┌─────────────┐     ┌──────────────────────────────────────┐    │
│  │  Synergy    │────▶│         LAN Bridge Proxy              │    │
│  │  Client     │     │                                       │    │
│  │             │     │  1. Listen on 127.0.0.1:24800        │    │
│  │ connects to │     │  2. Accept connection from Synergy   │    │
│  │ 127.0.0.1   │     │  3. Create new socket                │    │
│  └─────────────┘     │  4. Bind to 192.168.1.100 (LAN IP)  │    │
│                      │  5. Connect to 192.168.1.50:24800    │    │
│                      │  6. Forward data bidirectionally     │    │
│                      └──────────────────┬───────────────────┘    │
│                                         │                         │
│  ┌─────────────┐                       │                         │
│  │ VPN Tunnel  │                       │                         │
│  │   utun0     │◀── (not used) ───────┘                         │
│  │             │                       │                         │
│  └─────────────┘                       │                         │
│                                         │                         │
│  ┌─────────────┐                       │                         │
│  │ Physical    │◀──────────────────────┘                         │
│  │ Interface   │     (bound to 192.168.1.100)                    │
│  │    en0      │                                                  │
│  └──────┬──────┘                                                  │
└─────────┼─────────────────────────────────────────────────────────┘
          │
          │ Local Network (Ethernet/WiFi)
          │
          ▼
┌─────────────────┐
│  Synergy Server │
│  192.168.1.50   │
└─────────────────┘
```

### Why Binding Works

1. **Each interface has an IP**: `en0` has `192.168.1.100`, `utun0` has `10.153.43.39`
2. **Binding sets the source**: `sock.bind(('192.168.1.100', 0))`
3. **OS selects interface by source**: Traffic from `192.168.1.100` must go through `en0`
4. **VPN routing is bypassed**: The routing table isn't consulted for interface selection

### Data Flow

1. Synergy client connects to `127.0.0.1:24800`
2. Proxy accepts the connection
3. Proxy creates outbound socket bound to LAN IP
4. Proxy connects to actual server
5. Proxy forwards data between the two sockets
6. Both directions are handled by separate threads

```
Synergy → [local socket] → Proxy → [LAN-bound socket] → Server
                               ↑                    ↑
                           127.0.0.1            192.168.1.100
                           (loopback)           (LAN interface)
```

## Alternative Approaches

### Why Not Just Add Routes?

You might think: "Just add a more specific route for my server!"

```bash
sudo route add -host 192.168.1.50 192.168.1.1
```

**Problems:**
1. Many VPN clients **continuously maintain routes** and will override your changes
2. GlobalProtect, Cisco AnyConnect, etc. use kernel extensions that intercept routing
3. Routes may be reset on VPN reconnect

### Why Not Use Split Tunneling?

Split tunneling would solve this, but:
1. Most corporate VPNs **disable** split tunneling for security
2. Users typically **can't change** VPN configuration
3. IT policies often mandate full tunnel

### Why Not Change Home Network IP Range?

You could change your home router to use a different subnet:
1. This is disruptive (all devices need reconfiguration)
2. Corporate VPNs often route **all** private ranges
3. Some VPNs route **all** traffic (even public IPs)

## Limitations

### TCP Only

This proxy works for TCP connections. It doesn't help with:
- UDP traffic (gaming, some video conferencing)
- Broadcast/multicast (mDNS, Bonjour discovery)
- ICMP (ping)

### Single Service Per Port

Each proxy instance handles one destination. For multiple services, run multiple instances on different local ports.

### Latency

An extra hop is added to every packet:
```
Before: Client → Server (~0.5ms)
After:  Client → Proxy → Server (~0.6ms)
```

The added latency is negligible for most applications but may be noticeable for high-frequency input (fast mouse movements).

### No Authentication

The proxy doesn't add security. It relies on:
- The application's own authentication (Synergy uses TLS)
- Your local network security
- Firewall rules on both machines
