#!/usr/bin/env python3
"""
send_test_byte.py

Send a minimal Ethernet frame to the DE2-115 for the loopback test.

The FPGA's eth_loopback_test displays:
  HEX1:HEX0 = the value at byte 14 of the frame (first byte after EtherType)
  HEX3:HEX2 = frame counter

So if you run this with --value 0x42, the FPGA HEX1:HEX0 should show "42".

USAGE (Windows, in PowerShell as Administrator):
    pip install scapy
    # Find your Ethernet adapter name:
    python send_test_byte.py --list
    # Send byte 0x42 once:
    python send_test_byte.py --iface "Ethernet 5" --value 0x42
    # Spam frames continuously (one per 100 ms) to verify counter:
    python send_test_byte.py --iface "Ethernet 5" --value 0x42 --count 100 --gap 0.1

Notes:
  - Windows: requires Npcap (https://npcap.com) installed in "WinPcap-compatible mode"
  - You MUST run as Administrator to send raw frames
  - The destination MAC is broadcast (FF:FF:FF:FF:FF:FF) so the PHY doesn't
    care which port; just needs the cable plugged in.
"""

import argparse
import sys
import time

try:
    from scapy.all import Ether, Raw, sendp, get_if_list
    from scapy.config import conf
except ImportError:
    print("ERROR: scapy not installed. Run: pip install scapy", file=sys.stderr)
    sys.exit(1)


def list_interfaces():
    """List available Ethernet interfaces on this system."""
    print("Available interfaces:")
    print("-" * 60)
    for iface in get_if_list():
        try:
            # On Windows scapy uses long descriptive names
            print(f"  {iface}")
        except Exception:
            pass
    print()
    print("On Windows, also try:")
    print("  netsh interface show interface")


def build_frame(value: int, length: int = 64) -> bytes:
    """Build a raw Ethernet frame whose byte 14 = value."""
    # Byte layout (what eth_mac_bridge will deliver after preamble stripping):
    #   0-5   : dest MAC      (FF:FF:FF:FF:FF:FF, broadcast)
    #   6-11  : src MAC       (DE:AD:BE:EF:00:01, arbitrary)
    #   12-13 : EtherType     (0x88B5 = experimental/local)
    #   14    : our test byte  ← this is what HEX1:HEX0 will show
    #   15..  : padding
    #
    # Use a non-standard EtherType (0x88B5) so the laptop's network stack
    # won't try to interpret the frame as IP/ARP/etc and won't reject it.

    dst = "FF:FF:FF:FF:FF:FF"          # broadcast
    src = "DE:AD:BE:EF:00:01"          # arbitrary, not on the wire elsewhere
    ethertype = 0x88B5                 # IEEE-assigned experimental ethertype

    payload = bytes([value & 0xFF]) + bytes(length - 15)
    frame = Ether(dst=dst, src=src, type=ethertype) / Raw(load=payload)
    return frame


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true",
                    help="List available interfaces and exit")
    ap.add_argument("--iface", type=str, default=None,
                    help="Ethernet interface name (use --list to discover)")
    ap.add_argument("--value", type=lambda x: int(x, 0), default=0x42,
                    help="Byte value to send (e.g. 0x42 or 66). Default 0x42.")
    ap.add_argument("--count", type=int, default=1,
                    help="Number of frames to send (default 1)")
    ap.add_argument("--gap",   type=float, default=0.05,
                    help="Seconds between frames (default 0.05)")
    ap.add_argument("--size",  type=int, default=64,
                    help="Total frame size in bytes (min 64, default 64)")
    args = ap.parse_args()

    if args.list:
        list_interfaces()
        return 0

    if not args.iface:
        print("ERROR: --iface is required (or use --list to discover)")
        print("       Try: python send_test_byte.py --list")
        return 1

    if not (0 <= args.value <= 0xFF):
        print(f"ERROR: --value must be 0..255, got {args.value}")
        return 1

    frame = build_frame(args.value, length=max(args.size, 64))

    print(f"Sending {args.count} frame(s) on '{args.iface}'")
    print(f"  test byte (will show on HEX1:HEX0) = 0x{args.value:02X}")
    print(f"  frame size = {len(frame)} bytes")
    print()

    for i in range(args.count):
        sendp(frame, iface=args.iface, verbose=False)
        if (i + 1) % 10 == 0:
            print(f"  sent {i+1}/{args.count}")
        if i < args.count - 1:
            time.sleep(args.gap)

    print(f"Done. Sent {args.count} frame(s).")
    print()
    print("On the FPGA, you should see:")
    print(f"  HEX1:HEX0 = {args.value:02X}")
    print(f"  HEX3:HEX2 = {args.count & 0xFF:02X} (assuming counter was at 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
