#!/usr/bin/env python3
"""
VPN LAN Bridge - TCP Proxy for Bypassing VPN Routing

This proxy allows local network services to remain accessible when a VPN
captures traffic destined for your LAN subnet. It works by binding outbound
connections to your physical LAN IP, forcing traffic through the local
interface instead of the VPN tunnel.

Usage:
    ./lan-bridge.py                          # Use config.sh in parent directory
    ./lan-bridge.py --config /path/to/config # Use specific config file
    ./lan-bridge.py --lan-ip 192.168.1.100 --remote-host 192.168.1.50 --remote-port 24800

Environment variables (alternative to config file):
    LAN_BRIDGE_LOCAL_IP     Your computer's LAN IP
    LAN_BRIDGE_REMOTE_HOST  Remote service IP/hostname
    LAN_BRIDGE_REMOTE_PORT  Remote service port
    LAN_BRIDGE_PROXY_PORT   Local proxy port (default: same as remote)
"""

import argparse
import logging
import os
import signal
import socket
import subprocess
import sys
import threading
from pathlib import Path

# Defaults
DEFAULT_BUFFER_SIZE = 65536
DEFAULT_PROXY_HOST = '127.0.0.1'

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)


class LANBridge:
    """TCP proxy that binds to a specific source IP to bypass VPN routing."""

    def __init__(self, local_lan_ip: str, remote_host: str, remote_port: int,
                 proxy_host: str = DEFAULT_PROXY_HOST, proxy_port: int = None):
        self.local_lan_ip = local_lan_ip
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.proxy_host = proxy_host
        self.proxy_port = proxy_port or remote_port
        self.running = False
        self.server_socket = None
        self.connections = []

    def start(self):
        """Start the proxy server."""
        self.running = True

        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

        try:
            self.server_socket.bind((self.proxy_host, self.proxy_port))
        except OSError as e:
            logger.error(f"Failed to bind to {self.proxy_host}:{self.proxy_port}: {e}")
            logger.error("Is another instance already running?")
            sys.exit(1)

        self.server_socket.listen(5)
        self.server_socket.settimeout(1.0)

        logger.info(f"LAN Bridge started")
        logger.info(f"  Listening on:    {self.proxy_host}:{self.proxy_port}")
        logger.info(f"  Forwarding to:   {self.remote_host}:{self.remote_port}")
        logger.info(f"  Via LAN IP:      {self.local_lan_ip}")

        while self.running:
            try:
                client_sock, client_addr = self.server_socket.accept()
                logger.info(f"Connection from {client_addr[0]}:{client_addr[1]}")

                thread = threading.Thread(
                    target=self._handle_client,
                    args=(client_sock, client_addr),
                    daemon=True
                )
                thread.start()
                self.connections.append(thread)

            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    logger.error(f"Accept error: {e}")

        self._cleanup()

    def stop(self):
        """Stop the proxy server."""
        logger.info("Shutting down...")
        self.running = False

    def _handle_client(self, client_sock: socket.socket, client_addr: tuple):
        """Handle a single client connection."""
        remote_sock = None

        try:
            # Create socket bound to specific source IP (the key mechanism)
            remote_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote_sock.settimeout(10)

            # Bind to LAN IP before connecting - this bypasses VPN routing
            remote_sock.bind((self.local_lan_ip, 0))
            remote_sock.connect((self.remote_host, self.remote_port))

            logger.info(f"Connected to {self.remote_host}:{self.remote_port} via {self.local_lan_ip}")

            # Remove timeout for normal operation
            remote_sock.settimeout(None)
            client_sock.settimeout(None)

            # Bidirectional forwarding
            threads = [
                threading.Thread(target=self._forward, args=(client_sock, remote_sock, "client→remote"), daemon=True),
                threading.Thread(target=self._forward, args=(remote_sock, client_sock, "remote→client"), daemon=True),
            ]

            for t in threads:
                t.start()

            for t in threads:
                t.join()

        except socket.timeout:
            logger.warning(f"Connection to {self.remote_host}:{self.remote_port} timed out")
        except ConnectionRefusedError:
            logger.warning(f"Connection refused by {self.remote_host}:{self.remote_port}")
        except OSError as e:
            if "No route to host" in str(e):
                logger.error(f"No route to host - VPN may be blocking LAN access")
                logger.error(f"Verify LAN IP {self.local_lan_ip} is correct")
            else:
                logger.error(f"Connection error: {e}")
        except Exception as e:
            logger.error(f"Unexpected error: {e}")
        finally:
            self._close_socket(client_sock)
            self._close_socket(remote_sock)
            logger.debug(f"Connection from {client_addr[0]}:{client_addr[1]} closed")

    def _forward(self, src: socket.socket, dst: socket.socket, direction: str):
        """Forward data between two sockets."""
        try:
            while self.running:
                data = src.recv(DEFAULT_BUFFER_SIZE)
                if not data:
                    break
                dst.sendall(data)
        except Exception:
            pass

    def _close_socket(self, sock: socket.socket):
        """Safely close a socket."""
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                sock.close()
            except Exception:
                pass

    def _cleanup(self):
        """Clean up resources."""
        if self.server_socket:
            self._close_socket(self.server_socket)


def load_config(config_path: str) -> dict:
    """Load configuration from a shell-style config file."""
    config = {}

    if not os.path.exists(config_path):
        return config

    try:
        # Source the config file and extract variables
        result = subprocess.run(
            ['bash', '-c', f'source "{config_path}" && env'],
            capture_output=True,
            text=True
        )

        for line in result.stdout.split('\n'):
            if '=' in line:
                key, _, value = line.partition('=')
                config[key] = value

    except Exception as e:
        logger.warning(f"Failed to load config from {config_path}: {e}")

    return config


def find_config_file() -> str:
    """Find config file in standard locations."""
    locations = [
        Path(__file__).parent.parent / 'config.sh',
        Path.home() / '.config' / 'lan-bridge' / 'config.sh',
        Path('/etc/lan-bridge/config.sh'),
    ]

    for path in locations:
        if path.exists():
            return str(path)

    return None


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description='TCP proxy for bypassing VPN routing to local network services',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument('--config', '-c',
                        help='Path to config file (default: auto-detect)')
    parser.add_argument('--lan-ip', '-l',
                        help='Your computer\'s LAN IP address')
    parser.add_argument('--remote-host', '-r',
                        help='Remote service hostname or IP')
    parser.add_argument('--remote-port', '-p', type=int,
                        help='Remote service port')
    parser.add_argument('--proxy-port', type=int,
                        help='Local proxy port (default: same as remote)')
    parser.add_argument('--proxy-host', default=DEFAULT_PROXY_HOST,
                        help=f'Local proxy bind address (default: {DEFAULT_PROXY_HOST})')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Enable debug logging')

    return parser.parse_args()


def main():
    args = parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Load configuration (priority: CLI args > env vars > config file)
    config = {}

    # Try config file
    config_path = args.config or find_config_file()
    if config_path:
        logger.debug(f"Loading config from {config_path}")
        config = load_config(config_path)

    # Get values with fallback chain
    local_lan_ip = (
        args.lan_ip or
        os.environ.get('LAN_BRIDGE_LOCAL_IP') or
        config.get('LOCAL_LAN_IP') or
        config.get('LAN_BRIDGE_LOCAL_IP')
    )

    remote_host = (
        args.remote_host or
        os.environ.get('LAN_BRIDGE_REMOTE_HOST') or
        config.get('REMOTE_HOST') or
        config.get('LAN_BRIDGE_REMOTE_HOST')
    )

    remote_port_str = (
        str(args.remote_port) if args.remote_port else
        os.environ.get('LAN_BRIDGE_REMOTE_PORT') or
        config.get('REMOTE_PORT') or
        config.get('LAN_BRIDGE_REMOTE_PORT')
    )

    proxy_port_str = (
        str(args.proxy_port) if args.proxy_port else
        os.environ.get('LAN_BRIDGE_PROXY_PORT') or
        config.get('PROXY_PORT') or
        config.get('LAN_BRIDGE_PROXY_PORT') or
        remote_port_str
    )

    # Validate required parameters
    if not all([local_lan_ip, remote_host, remote_port_str]):
        logger.error("Missing required configuration")
        logger.error("Required: --lan-ip, --remote-host, --remote-port")
        logger.error("Or set in config file / environment variables")
        if not config_path:
            logger.error("No config file found. Create config.sh or use --config")
        sys.exit(1)

    try:
        remote_port = int(remote_port_str)
        proxy_port = int(proxy_port_str) if proxy_port_str else remote_port
    except ValueError as e:
        logger.error(f"Invalid port number: {e}")
        sys.exit(1)

    # Create and start bridge
    bridge = LANBridge(
        local_lan_ip=local_lan_ip,
        remote_host=remote_host,
        remote_port=remote_port,
        proxy_host=args.proxy_host,
        proxy_port=proxy_port
    )

    # Handle signals
    def signal_handler(sig, frame):
        bridge.stop()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Start the bridge
    bridge.start()


if __name__ == '__main__':
    main()
